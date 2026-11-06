import SwiftUI

/// 合并后的设置页：AI、工作方式、相机能力、隐私与费用、照片找回。
struct SettingsView: View {
    @Bindable var model: CameraModel
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var error: String?

    private var state: CameraState { model.state }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("模型", value: AICredentials.displayName)
                    LabeledContent("API", value: "api.deepseek.com")
                    LabeledContent("密钥") {
                        Text(model.hasAPIKey ? "已存入本机 Keychain" : "尚未配置")
                            .foregroundStyle(model.hasAPIKey ? Theme.Palette.accent : Theme.Palette.warning)
                    }
                    SecureField("输入新的 API 密钥", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("保存密钥") {
                        do {
                            try model.saveAPIKey(key)
                            key = ""
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if model.hasAPIKey {
                        Button("移除本机密钥", role: .destructive) {
                            do { try model.removeAPIKey() } catch { self.error = error.localizedDescription }
                        }
                    }
                    if let error { Text(error).foregroundStyle(Theme.Palette.warning) }
                } header: {
                    Text("AI")
                }

                Section("AI 如何工作") {
                    Text("开启后，AI 定期查看压缩取景图和硬件实际读数，选择画幅、变焦、光圈、ISO、快门和曝光补偿；执行后再看新画面，决定保持还是继续调整。")
                    Text("每次只发送一个请求，两轮之间至少间隔 5 秒。画面变化时上一轮建议会被丢弃。")
                    Text("取景框扫过的青色细线，表示 AI 刚截取了一帧；青色读数是 AI 设定的值，白色是你设定的值。")
                    Text("手动调整光圈、曝光、画幅或变焦会停止 AI；点按对焦不会。")
                }

                Section("相机") {
                    LabeledContent("镜头", value: state.lensName)
                    LabeledContent("光圈优先", value: state.supportsAperturePriority ? "支持" : "不可用")
                    if let range = state.apertureRange {
                        LabeledContent("硬件光圈",
                                       value: "\(CameraText.aperture(range.minimum)) – \(CameraText.aperture(range.maximum))")
                    }
                    LabeledContent("数字变焦",
                                   value: "\(CameraText.zoom(state.minZoom)) – \(CameraText.zoom(state.maxZoom))")
                    Text("取景读数来自硬件回读，可能与目标值略有偏差。手动光圈下，弱光多帧处理与自动模式可能不同。")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("隐私与费用") {
                    Text("普通拍摄在本机完成。AI 开启时，压缩取景图和相机参数会通过 HTTPS 发送给模型服务商，按你的 API 账户计费；关闭 AI 后不再发送。")
                    Text("密钥保存在这台 iPhone 的 Keychain，不打包进 App，不写入日志。")
                }

                Section("照片找回") {
                    Text("图库保存失败时，原图保留在「文件 → 我的 iPhone → Logit Camera → 待保存照片」，关闭应用后仍可找回。")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.background)
            .navigationTitle("Logit Camera")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        .tint(Theme.Palette.accent)
        .preferredColorScheme(.dark)
    }
}
