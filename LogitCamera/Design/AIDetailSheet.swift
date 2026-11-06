import CameraCore
import SwiftUI

/// AI 详情：当前方案、拍摄条件、七项评分与证据、决策记录、自动拍摄开关。Agent 照常运行。
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

                if let plan = agent.plan, !agent.isDefaultPlan {
                    Section("拍摄方案 · \(agent.genreName ?? plan.genre.rawValue)") {
                        Text(plan.rationale)
                        LabeledContent("构图") { Text(AgentText.composition(plan.composition)).font(.caption) }
                        LabeledContent("曝光") { Text(AgentText.exposure(plan.exposure)).font(.caption) }
                    }
                }

                if let report = agent.report, !agent.isDefaultPlan {
                    Section("拍摄条件（全部满足即拍）") {
                        ForEach(Array(report.statuses.enumerated()), id: \.offset) { _, status in
                            HStack {
                                Image(systemName: status.satisfied ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(status.satisfied ? Theme.Palette.accent : .secondary)
                                Text(AgentText.trigger(status.trigger.kind))
                                Spacer()
                                if let threshold = status.trigger.threshold {
                                    Text(String(format: "%.2f", threshold)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if let rubric = agent.rubric {
                    Section("评审评分") {
                        RubricBars(result: rubric, weights: agent.rubricWeights,
                                   genreName: agent.plan.flatMap { try? Knowledge.playbook($0.genre).genreCriterion.name } ?? "题材特有项")
                            .padding(.vertical, 4)
                    }
                }

                Section {
                    Toggle(isOn: Binding(get: { agent.autoCaptureEnabled }, set: model.setAutoCapture)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("自动拍摄")
                            Text(agent.autoCaptureEnabled ? "评审放行后，条件全部满足的瞬间拍一张" : "AI 只提示「就绪」，由你按下快门")
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
                    Text("AI 没有快门权限：它只给出方案和评分，由相机在条件满足时按下快门。每个场景自动拍一张。")
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
