import SwiftUI

struct AISettingsView: View {
    @Bindable var model: CameraModel
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("DeepSeek") {
                    LabeledContent("模型", value: AICredentials.displayName)
                    LabeledContent("API", value: "api.deepseek.com")
                    LabeledContent("密钥", value: model.hasAPIKey ? "已存入本机 Keychain" : "尚未配置")
                    SecureField("输入新的 API 密钥", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("保存密钥") {
                        do {
                            try model.saveAPIKey(key)
                            key = ""
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if model.hasAPIKey {
                        Button("移除本机密钥", role: .destructive) {
                            do { try model.removeAPIKey() }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                }
                Section("持续构图") {
                    Text("开启后，AI 定期查看压缩取景图和实际参数，选择画幅、变焦、光圈、ISO、快门和曝光补偿；执行后再看新画面决定保持或继续调整。")
                    Text("每次只发送一个请求，两轮之间至少间隔 5 秒。手动调参会关闭 AI；拍照与切后台时暂停。")
                }
                Section("图像与费用") {
                    Text("AI 开启时会通过 HTTPS 将压缩取景图发送至 DeepSeek，按你的 API 账户计费。关闭 AI 后不再发送；照片拍摄与保存仍在本机完成。")
                    Text("密钥保存在这台 iPhone 的 Keychain，不打包进 App，不显示在日志中。")
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("AI 设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }.preferredColorScheme(.dark)
    }
}
