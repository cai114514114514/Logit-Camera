import CameraCore
import SwiftUI

/// 快门上方的一行人话：「● 人像 · 2× 浅景深」。整行是按钮，点开 AI 详情（技术细节都在那里）。
struct AIStatusLine: View {
    let agent: AgentController
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: dotColor.opacity(0.8), radius: agent.isEnabled ? 4 : 0)
                Text(summary)
                    .foregroundStyle(agent.faulted ? Theme.Palette.warning : Theme.Palette.ink)
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Palette.inkTertiary)
            }
            .font(.system(.footnote, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hudTypeSize()
        .accessibilityLabel(["AI", summary, agent.caption ?? "", agent.reason].filter { !$0.isEmpty }.joined(separator: "。"))
        .accessibilityValue("第 \(agent.calls) 轮")
        .accessibilityHint("打开 AI 详情")
        .accessibilityIdentifier("camera.agent")
    }

    private var dotColor: Color {
        if agent.faulted { return Theme.Palette.warning }
        return agent.isEnabled && ![.paused, .cooldown].contains(agent.phase) ? Theme.Palette.accent : Theme.Palette.inkTertiary
    }

    /// 一句人话：题材 · 焦段与景深；没有题材时说 AI 在做什么。
    var summary: String {
        if agent.faulted { return agent.status }
        guard agent.isEnabled else { return "AI 已关闭" }
        switch agent.phase {
        case .cooldown: return "拍好了"
        case .paused: return "已暂停"
        case .scouting: return "AI 在看"
        default: break
        }
        var parts: [String] = []
        if agent.isOffline { parts.append("离线") }
        parts.append(agent.genreName ?? "AI")
        var lensText: [String] = []
        if let lens = agent.lens { lensText.append(CameraText.zoom(Float(lens.zoomFactor))) }
        switch agent.plan?.exposure.depth {
        case .shallow?: lensText.append("浅景深")
        case .deep?: lensText.append("大景深")
        default: break
        }
        if !lensText.isEmpty { parts.append(lensText.joined(separator: " ")) }
        return parts.joined(separator: " · ")
    }
}
