import CameraCore
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

private struct PhotoExport: Transferable {
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .jpeg) { $0.data }
            .suggestedFileName("Logit-Photo.jpg")
    }
}

struct PhotoDetailView: View {
    @Bindable var model: CameraModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDiscard = false
    @State private var selectedAlternate: Int?
    @State private var thumbnails: [Int: UIImage] = [:]

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let photo = model.latestPhoto {
                    Group {
                        if let image = model.preview ?? model.thumbnail {
                            Image(uiImage: image).resizable().scaledToFit()
                        } else {
                            ProgressView().tint(Theme.Palette.inkSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    exif(photo)
                    if model.alternates.count > 1 { alternatesStrip }
                    actions(photo)

                    if let notice = model.notice {
                        Text(notice.text)
                            .font(.footnote)
                            .foregroundStyle(notice.isWarning ? Theme.Palette.warning : Theme.Palette.inkSecondary)
                            .multilineTextAlignment(.center)
                    }
                    if model.hasUnprotectedPhoto && !model.isSaving {
                        Button("丢弃这张未保存的照片", role: .destructive) { confirmsDiscard = true }
                            .font(.footnote)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Palette.background)
            .navigationTitle("刚刚拍摄")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .confirmationDialog("照片没有保存，确定丢弃吗？", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                Button("丢弃照片", role: .destructive) {
                    model.discardUnprotectedPhoto()
                    dismiss()
                }
            }
        }
        .tint(Theme.Palette.accent)
        .preferredColorScheme(.dark)
    }

    /// 连拍备选：AI 选中的那张标出来；选另一张后可以「换成这张」（也存入相册）。
    private var alternatesStrip: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.alternates) { alternate in
                        Button { selectedAlternate = alternate.index } label: {
                            thumbnail(alternate)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(alternate.isAIChoice ? "第 \(alternate.index + 1) 张，AI 选择" : "第 \(alternate.index + 1) 张")
                    }
                }
                .padding(.horizontal, 2)
            }
            .accessibilityIdentifier("photo.alternates")
            if let index = selectedAlternate, let alternate = model.alternates.first(where: { $0.index == index }),
               !alternate.isAIChoice {
                Button {
                    Task { await model.saveAlternate(alternate) }
                } label: {
                    Label("换成这张", systemImage: "arrow.triangle.2.circlepath").frame(minHeight: 36)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("photo.useAlternate")
            }
        }
        .task(id: model.alternates.map(\.url)) { await loadThumbnails() }
    }

    private func thumbnail(_ alternate: BurstAlternate) -> some View {
        let selected = selectedAlternate == alternate.index || (selectedAlternate == nil && alternate.isAIChoice)
        return ZStack(alignment: .bottom) {
            Group {
                if let image = thumbnails[alternate.index] {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(Theme.Palette.hairline)
                }
            }
            .frame(width: 56, height: 74)
            .clipped()
            if alternate.isAIChoice {
                Text("AI 选择")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Theme.Palette.accent, in: Capsule())
                    .foregroundStyle(.black)
                    .padding(.bottom, 3)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Theme.Palette.accent : .clear, lineWidth: 2))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func loadThumbnails() async {
        let urls = model.alternates.map { ($0.index, $0.url) }
        let loaded = await Task.detached(priority: .userInitiated) {
            urls.compactMap { index, url -> (Int, CGImage)? in
                guard let data = try? Data(contentsOf: url), let image = PhotoMetadata.downsample(data, maxPixel: 200)
                else { return nil }
                return (index, image)
            }
        }.value
        thumbnails = Dictionary(uniqueKeysWithValues: loaded.map { ($0.0, UIImage(cgImage: $0.1)) })
    }

    private func exif(_ photo: CapturedPhoto) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 22) {
                Text(CameraText.aperture(photo.aperture.map(Float.init)))
                Text(photo.iso.map { "ISO " + String(Int($0.rounded())) } ?? "ISO —")
                Text(CameraText.shutter(photo.exposureSeconds))
            }
            .font(Theme.Typeface.readoutLarge)
            .foregroundStyle(Theme.Palette.ink)
            HStack(spacing: 8) {
                Text("EXIF")
                Rectangle().fill(Theme.Palette.hairline).frame(width: 1, height: 10)
                Text(model.photoPixelSize.map { "\(Int($0.width)) × \(Int($0.height))" } ?? "—")
                    .monospacedDigit()
                    .accessibilityIdentifier("photo.dimensions")
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.Palette.inkTertiary)
        }
    }

    private func actions(_ photo: CapturedPhoto) -> some View {
        HStack(spacing: 14) {
            Button {
                Task { await model.saveLatestPhoto() }
            } label: {
                Label(model.photoSaved ? "已保存" : "保存到照片",
                      systemImage: model.photoSaved ? "checkmark" : "square.and.arrow.down")
                    .frame(minHeight: 44)
            }
            .disabled(model.photoSaved || model.isSaving)
            if let image = model.preview ?? model.thumbnail {
                ShareLink(item: PhotoExport(data: photo.data),
                          preview: SharePreview("Logit Camera", image: Image(uiImage: image))) {
                    Label("分享原图", systemImage: "square.and.arrow.up").frame(minHeight: 44)
                }
            }
        }
        .buttonStyle(.bordered)
    }
}
