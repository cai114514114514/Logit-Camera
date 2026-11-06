import CameraCore
import SwiftUI

/// 拍摄条件小标记：满足 ✓（青色），未满足 ○（灰色）。
struct TriggerChips: View {
    let report: TriggerReport

    var body: some View {
        ViewThatFits(in: .horizontal) {
            chips(showSatisfied: true)
            chips(showSatisfied: false)
        }
        .font(.system(.caption2, design: .monospaced, weight: .medium))
        .lineLimit(1)
        // 位于状态线按钮内：无障碍文字由按钮统一给出，这里不设标识，避免覆盖 camera.agent。
        .accessibilityHidden(true)
    }

    private func chips(showSatisfied: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(report.statuses.enumerated()), id: \.offset) { _, status in
                if showSatisfied || !status.satisfied {
                    HStack(spacing: 1) {
                        Text(AgentText.trigger(status.trigger.kind))
                        Image(systemName: status.satisfied ? "checkmark" : "circle")
                            .font(.system(size: 7, weight: .bold))
                    }
                    .foregroundStyle(status.satisfied ? Theme.Palette.accent : Theme.Palette.inkTertiary)
                }
            }
        }
    }
}
