import SwiftUI

/// 快门上方的一行 AI 状态。整行是按钮，点开 AI 详情。
struct AIStatusLine: View {
    let agent: CameraAgent
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                dot
                Text(stageText)
                    .foregroundStyle(agent.faulted ? Theme.Palette.warning : Theme.Palette.ink)
                if agent.isEnabled {
                    Text("·").foregroundStyle(Theme.Palette.inkTertiary)
                    Text("第 \(agent.round) 轮")
                        .foregroundStyle(Theme.Palette.inkSecondary)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 8)
                if agent.isEnabled {
                    confirmations
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
            .animation(.snappy(duration: 0.2), value: agent.round)
        }
        .buttonStyle(.plain)
        .hudTypeSize()
        .accessibilityLabel(["AI", stageText, agent.reason].filter { !$0.isEmpty }.joined(separator: "。"))
        .accessibilityValue("第 \(agent.round) 轮")
        .accessibilityHint("打开 AI 详情")
        .accessibilityIdentifier("camera.agent")
    }

    var stageText: String {
        if agent.faulted { return agent.status }
        guard agent.isEnabled else { return "AI 已关闭" }
        return switch agent.stage {
        case .observing: "观察中"
        case .thinking: "分析中"
        case .applying: "调整中"
        case .verifying: "复核中"
        case .ready: "准备拍摄"
        case .countdown: "即将拍摄"
        case .paused: "已暂停"
        }
    }

    @ViewBuilder private var dot: some View {
        let looking = agent.isEnabled && (agent.stage == .observing || agent.stage == .thinking)
        let color: Color = agent.faulted ? Theme.Palette.warning
            : (agent.isEnabled && agent.stage != .paused ? Theme.Palette.accent : Theme.Palette.inkTertiary)
        let symbol = agent.faulted ? "exclamationmark.circle.fill"
            : (agent.stage == .ready || agent.stage == .countdown ? "smallcircle.filled.circle" : "circle.fill")
        Image(systemName: symbol)
            .font(.system(size: agent.stage == .ready || agent.stage == .countdown ? 10 : 7))
            .foregroundStyle(color)
            .symbolEffect(.pulse, options: .repeating, isActive: looking)
            .frame(width: 12)
    }

    /// 两次模型确认：●○ 表示 1/2。
    private var confirmations: some View {
        HStack(spacing: 3) {
            ForEach(0..<2, id: \.self) { index in
                Circle()
                    .fill(index < agent.confirmationCount ? Theme.Palette.accent : .clear)
                    .overlay(Circle().stroke(index < agent.confirmationCount ? Theme.Palette.accent : Theme.Palette.inkTertiary,
                                             lineWidth: 1))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }
}
