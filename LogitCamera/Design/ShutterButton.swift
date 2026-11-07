import CameraCore
import SwiftUI

/// 快门：任何时候点按都立即拍摄（AI 开启时连拍并在本机选片）。
/// AI 取景时外圈的青色亮度跟随时机分：越接近好时机越亮，好时机到来时 AI 会自己按下。
struct ShutterButton: View {
    let model: CameraModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var agent: AgentController { model.agent }
    /// 0…1：AI 认为「现在拍」有多好。
    private var readiness: Double? {
        guard agent.isEnabled, [.planning, .composing, .capturing].contains(agent.phase) else { return nil }
        return agent.phase == .capturing ? 1 : agent.moment?.score
    }
    private var busy: Bool { model.capturePending || model.state.isCapturing || model.isSaving || model.isSelecting }
    private var disabled: Bool { !model.canTakePhoto }

    var body: some View {
        Button(action: model.takePhoto) { rings }
            .buttonStyle(.plain)
            .disabled(disabled)
            .opacity(disabled && !busy ? 0.4 : 1)
            .accessibilityLabel("拍照并保存")
            .accessibilityValue(readiness.map { $0 >= 0.9 ? "AI 认为现在是好时机" : "AI 取景中" } ?? "")
            .accessibilityIdentifier("camera.shutter")
            .sensoryFeedback(.impact(weight: .medium), trigger: model.state.isCapturing)
    }

    private var rings: some View {
        ZStack {
            if let readiness {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || readiness < 0.9)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                    let breath = readiness >= 0.9 && !reduceMotion ? 0.75 + 0.25 * (0.5 - 0.5 * cos(phase * 2 * .pi)) : 1
                    let level = (0.25 + 0.75 * min(max(readiness, 0), 1)) * breath
                    Circle()
                        .stroke(Theme.Palette.accent.opacity(level), lineWidth: 3)
                        .shadow(color: Theme.Palette.accent.opacity(0.6 * level * readiness), radius: 8)
                }
                .frame(width: 78, height: 78)
                .animation(.easeOut(duration: 0.3), value: readiness)
            } else {
                Circle().stroke(Theme.Palette.ink, lineWidth: 2).frame(width: 78, height: 78)
            }
            let size: CGFloat = busy ? 54 : 64
            Circle().fill(Color.white).frame(width: size, height: size)
                .animation(.snappy(duration: 0.15), value: busy)
            if busy { ProgressView().tint(.black) }
        }
        .frame(width: 84, height: 84)
        .contentShape(Circle())
    }
}
