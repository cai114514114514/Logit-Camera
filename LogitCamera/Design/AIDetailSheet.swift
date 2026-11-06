import CameraCore
import SwiftUI

/// 点开状态线后的 AI 详情：完整理由、最近一次变化、自动拍摄开关。Agent 照常运行。
struct AIDetailSheet: View {
    let model: CameraModel
    @Environment(\.dismiss) private var dismiss

    private var agent: CameraAgent { model.agent }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Circle().fill(agent.isEnabled ? Theme.Palette.accent : Theme.Palette.inkTertiary)
                                .frame(width: 7, height: 7)
                            Text(agent.status).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("第 \(agent.round) 轮 · 确认 \(agent.confirmationCount)/2")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(agent.reason.isEmpty ? "还没有调整理由。开启 AI 后，每轮的判断会显示在这里。" : agent.reason)
                            .font(.callout)
                            .foregroundStyle(agent.reason.isEmpty ? .secondary : .primary)
                    }
                    .padding(.vertical, 4)
                }

                if !agent.changes.isEmpty {
                    Section("最近一次调整（硬件回读）") {
                        ForEach(agent.changes) { change in
                            LabeledContent(change.title) {
                                HStack(spacing: 6) {
                                    Text(change.before).foregroundStyle(.secondary)
                                    Image(systemName: "arrow.right").font(.caption2)
                                    Text(change.after).foregroundStyle(Theme.Palette.accent)
                                }
                                .font(.system(.callout, design: .monospaced))
                            }
                        }
                    }
                }

                Section {
                    Toggle(isOn: Binding(get: { agent.autoCaptureEnabled }, set: model.setAutoCapture)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("自动拍摄")
                            Text(agent.autoCaptureEnabled ? "两次确认且画面稳定后，倒计时 3 秒拍一张" : "由你按下快门")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("camera.autoCapture")
                    if agent.autoCaptureEnabled && !agent.captureArmed {
                        Button {
                            model.armAutoCapture()
                        } label: {
                            Label("再拍一张", systemImage: "camera")
                        }
                        .disabled(model.state.phase != .ready || model.isSaving || model.capturePending)
                        .accessibilityIdentifier("camera.rearm")
                    }
                } footer: {
                    Text("AI 没有直接按快门的能力：它只能声明「可以拍」，由相机检查稳定性后倒计时。")
                }

                Section {
                    LabeledContent("模型", value: agent.modelName)
                } footer: {
                    Text("AI 开启时，压缩取景图和相机参数会通过 HTTPS 发送给模型服务商。")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.background)
            .navigationTitle("AI 副驾驶")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        .tint(Theme.Palette.accent)
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
