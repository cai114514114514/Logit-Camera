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
            VStack(spacing: 22) {
                if let image = model.thumbnail, let photo = model.latestPhoto {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: .infinity)
                    HStack(spacing: 24) {
                        Text(CameraText.aperture(photo.aperture.map(Float.init)))
                        Text(photo.iso.map { "ISO " + String(Int($0.rounded())) } ?? "ISO —")
                        Text(CameraText.shutter(photo.exposureSeconds))
                    }
                    .font(.system(.subheadline, design: .monospaced))
                    Text("以上数值读取自这张照片的 EXIF")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("\(Int(image.size.width)) × \(Int(image.size.height))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityIdentifier("photo.dimensions")
                    HStack(spacing: 24) {
                        Button {
                            Task { await model.saveLatestPhoto() }
                        } label: {
                            Label(model.photoSaved ? "已保存" : "保存到照片", systemImage: model.photoSaved ? "checkmark" : "square.and.arrow.down")
                        }
                        .disabled(model.photoSaved || model.isSaving)
                        ShareLink(item: PhotoExport(data: photo.data),
                                  preview: SharePreview("Logit Camera", image: Image(uiImage: image))) {
                            Label("分享原图", systemImage: "square.and.arrow.up")
                        }
                    }.buttonStyle(.bordered)
                    if let notice = model.notice {
                        Text(notice).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    if model.hasUnprotectedPhoto && !model.isSaving {
                        Button("丢弃这张未保存的照片", role: .destructive) { confirmsDiscard = true }
                            .font(.footnote)
                    }
                }
            }
            .padding().navigationTitle("刚刚拍摄").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .background(.black)
            .confirmationDialog("照片没有保存，确定丢弃吗？", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                Button("丢弃照片", role: .destructive) {
                    model.discardUnprotectedPhoto()
                    dismiss()
                }
            }
        }.preferredColorScheme(.dark)
    }
}

struct CameraInfoView: View {
    let state: CameraState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("当前相机") {
                    LabeledContent("镜头", value: state.lensName)
                    LabeledContent("光圈优先", value: state.supportsAperturePriority ? "支持" : "不可用")
                    if let range = state.apertureRange {
                        LabeledContent("硬件范围", value: "\(CameraText.aperture(range.minimum)) – \(CameraText.aperture(range.maximum))")
                    }
                }
                Section("使用方式") {
                    Text("选择光圈后，系统自动配合快门和 ISO。取景下方显示镜头实际读数，可能与目标光圈略有偏差。")
                    Text("轻点取景画面设置对焦和测光位置。EV 滑块调整画面明暗；复位恢复系统自动设置。")
                    Text("手动光圈拍摄优先保持设置，弱光下多帧处理与自动模式可能不同。请持稳手机，并对比实际成片。")
                }
                Section("本地拍摄") {
                    Text("普通拍摄在本机完成。开启 DeepSeek AI 后，压缩取景图和当前参数会发送给 DeepSeek 分析；关闭 AI 后停止发送。")
                    Text("图库保存失败时，原图保留在「文件 → 我的 iPhone → Logit Camera → 待保存照片」，关闭应用后仍可找回。")
                }
            }
            .navigationTitle("Logit Camera").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }.preferredColorScheme(.dark)
    }
}
