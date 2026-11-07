import CameraCore
import SwiftUI

/// 快门上方的一行 AI 状态：阶段 + 时机信号标记。整行是按钮，点开 AI 详情。
struct AIStatusLine: View {
    let agent: AgentController
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                dot
                Text(stageText)
                    .foregroundStyle(agent.faulted ? Theme.Palette.warning : Theme.Palette.ink)
                    .layoutPriority(1)
                if let genre = agent.genreName, agent.isEnabled {
                    Text("· \(genre)").foregroundStyle(Theme.Palette.inkSecondary)
                }
                Spacer(minLength: 8)
                if agent.isEnabled, let report = agent.moment, [.planning, .composing].contains(agent.phase) {
                    TriggerChips(report: report)
                }
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Palette.inkTertiary)
            }
            .font(Theme.Typeface.bodyMono)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(height: Theme.Metric.statusHeight)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hudTypeSize()
        .accessibilityLabel(["AI", stageText, AgentText.waiting(agent.moment) ?? "", agent.reason]
            .filter { !$0.isEmpty }.joined(separator: "。"))
        .accessibilityValue("第 \(agent.calls) 轮")
        .accessibilityHint("打开 AI 详情")
        .accessibilityIdentifier("camera.agent")
    }

    var stageText: String {
        if agent.faulted { return agent.status }
        return agent.isEnabled ? agent.status : "AI 已关闭"
    }

    @ViewBuilder private var dot: some View {
        let phase = agent.phase
        let looking = agent.isEnabled && [.scouting, .planning].contains(phase)
        let armed = phase == .capturing || (phase == .composing && (agent.moment?.score ?? 0) >= 0.9)
        let color: Color = agent.faulted ? Theme.Palette.warning
            : (agent.isEnabled && phase != .paused && phase != .cooldown ? Theme.Palette.accent : Theme.Palette.inkTertiary)
        Image(systemName: agent.faulted ? "exclamationmark.circle.fill" : (armed ? "smallcircle.filled.circle" : "circle.fill"))
            .font(.system(size: armed ? 10 : 7))
            .foregroundStyle(color)
            .symbolEffect(.pulse, options: .repeating, isActive: looking)
            .frame(width: 12)
    }
}
