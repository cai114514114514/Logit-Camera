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
