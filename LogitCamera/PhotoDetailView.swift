import CameraCore
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

private struct PhotoExport: Transferable {
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .heic) { $0.data }
            .suggestedFileName("Logit-Photo.heic")
        DataRepresentation(exportedContentType: .jpeg) { $0.data }
            .suggestedFileName("Logit-Photo.jpg")
    }
}

private struct JPEGExport: Transferable {
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
    @State private var relook: LookRecipe?
    @State private var relookPreview: UIImage?
    @State private var lookThumbnails: [String: UIImage] = [:]
    @State private var savingLook = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let photo = model.latestPhoto {
                    Group {
                        if let image = relookPreview ?? model.preview ?? model.thumbnail {
                            Image(uiImage: image).resizable().scaledToFit()
                        } else {
                            ProgressView().tint(Theme.Palette.inkSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    exif(photo)
                    if model.latestOriginal != nil { relookStrip }
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

    /// 拍后换滤镜：基于这张照片的原片重新渲染；满意后另存为新照片（原来那张保留）。
    private var relookStrip: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.presets + model.myLooks, id: \.name) { look in
                        Button { choose(look) } label: {
                            VStack(spacing: 3) {
                                Group {
                                    if let image = lookThumbnails[look.name] {
                                        Image(uiImage: image).resizable().scaledToFill()
                                    } else {
                                        Rectangle().fill(Theme.Palette.hairline)
                                    }
                                }
                                .frame(width: 44, height: 58)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5)
                                    .stroke(relook?.name == look.name ? Color.white : .clear, lineWidth: 2))
                                Text(look.name).font(.system(size: 10)).lineLimit(1).frame(width: 52)
                                    .foregroundStyle(relook?.name == look.name ? Theme.Palette.ink : Theme.Palette.inkSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("detail.look.\(look.name)")
                    }
                }
                .padding(.horizontal, 2)
            }
            .accessibilityIdentifier("detail.looks")
            if let relook {
                Button {
                    savingLook = true
                    Task {
                        await model.saveAsNewPhoto(look: relook)
                        savingLook = false
                    }
                } label: {
                    Label(savingLook ? "正在保存…" : "用「\(relook.name)」另存为新照片", systemImage: "plus.square.on.square")
                        .frame(minHeight: 36)
                }
                .buttonStyle(.bordered)
                .disabled(savingLook)
                .accessibilityIdentifier("detail.saveLook")
            }
        }
        .task(id: model.latestOriginal?.id) { await loadLookThumbnails() }
    }

    private func choose(_ look: LookRecipe) {
        relook = look
        guard let data = model.latestOriginal?.data else { return }
        Task {
            let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let source = LookThumbnails.source(from: data, longSide: 1600) else { return nil }
                return LookThumbnails.render(source, look)
            }.value
            if relook?.name == look.name { relookPreview = image }
        }
    }

    private func loadLookThumbnails() async {
        guard let data = model.latestOriginal?.data else { return }
        relook = nil
        relookPreview = nil
        let looks = model.presets + model.myLooks
        lookThumbnails = await Task.detached(priority: .utility) { () -> [String: UIImage] in
            guard let source = LookThumbnails.source(from: data, longSide: 120) else { return [:] }
            var result: [String: UIImage] = [:]
            for look in looks { result[look.name] = LookThumbnails.render(source, look) }
            return result
        }.value
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
                Group {
                    if photo.isHEIC {
                        ShareLink(item: PhotoExport(data: photo.data),
                                  preview: SharePreview("Logit Camera", image: Image(uiImage: image))) {
                            Label("分享照片", systemImage: "square.and.arrow.up").frame(minHeight: 44)
                        }
                    } else {
                        ShareLink(item: JPEGExport(data: photo.data),
                                  preview: SharePreview("Logit Camera", image: Image(uiImage: image))) {
                            Label("分享照片", systemImage: "square.and.arrow.up").frame(minHeight: 44)
                        }
                    }
                }
            }
        }
        .buttonStyle(.bordered)
    }
}
