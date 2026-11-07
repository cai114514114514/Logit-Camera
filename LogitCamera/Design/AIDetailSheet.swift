import CameraCore
import SwiftUI

/// AI 详情：当前意图（焦段、构图、曝光）、时机信号、导演点评、决策记录、自动拍摄开关。Agent 照常运行。
struct AIDetailSheet: View {
    let model: CameraModel
    @Environment(\.dismiss) private var dismiss

    private var agent: AgentController { model.agent }

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
                            Text("第 \(agent.calls) 轮").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text(agent.reason.isEmpty ? "开启 AI 后，导演的判断会显示在这里。" : agent.reason)
                            .font(.callout)
                            .foregroundStyle(agent.reason.isEmpty ? .secondary : .primary)
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Toggle(isOn: Binding(get: { agent.autoCaptureEnabled }, set: model.setAutoCapture)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("自动拍摄")
                            Text(agent.autoCaptureEnabled ? "AI 判断时机好时自己连拍一组" : "AI 只调好参数，由你按下快门")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("camera.autoCapture")
                    if agent.phase == .cooldown {
                        Button {
                            model.armAutoCapture()
                        } label: {
                            Label("再拍一张", systemImage: "camera")
                        }
                        .accessibilityIdentifier("camera.rearm")
                    }
                } footer: {
                    Text("AI 掌控镜头、光圈、快门、ISO 与构图；你随时可以按快门。每次拍摄连拍 6 张，在本机挑出最好的一张。每个场景自动拍一组。")
                }

                if let plan = agent.plan {
                    Section("拍摄意图 · \(agent.genreName ?? plan.genre.rawValue)\(agent.isDefaultPlan ? "（题材默认）" : "")") {
                        if !agent.isDefaultPlan { Text(plan.rationale) }
                        LabeledContent("焦段") { Text(AgentText.lens(plan, current: agent.lens)).font(.caption) }
                        LabeledContent("构图") { Text(AgentText.composition(plan.composition)).font(.caption) }
                        LabeledContent("曝光") { Text(AgentText.exposure(plan.exposure)).font(.caption) }
                    }
                }

                if let report = agent.moment {
                    Section {
                        LabeledContent("时机分") {
                            Text(String(format: "%.0f%%", report.score * 100)).font(.caption.monospacedDigit())
                        }
                        ForEach(Array(report.statuses.filter(\.available).enumerated()), id: \.offset) { _, status in
                            HStack {
                                Image(systemName: status.satisfied ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(status.satisfied ? Theme.Palette.accent : .secondary)
                                Text(AgentText.trigger(status.trigger.kind))
                                Spacer()
                                Text(String(format: "%.2f", status.trigger.threshold)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("时机信号")
                    } footer: {
                        Text("信号全部满足时立即拍；否则等待最多 4 秒，拍下这段时间里最好的一刻。")
                    }
                }

                if let critique = agent.critique {
                    Section("导演点评") {
                        RubricBars(result: critique, weights: agent.rubricWeights,
                                   genreName: agent.plan.flatMap { try? Knowledge.playbook($0.genre).genreCriterion.name } ?? "题材特有项")
                            .padding(.vertical, 4)
                    }
                }

                if !agent.history.isEmpty {
                    Section("最近决策") {
                        ForEach(agent.history) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.text).font(.caption)
                                Text(entry.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    LabeledContent("模型", value: agent.modelName)
                } footer: {
                    Text("AI 开启时，压缩取景图和相机参数会通过 HTTPS 发送给模型服务商。")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.background)
            .navigationTitle("AI 导演")
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
