import CameraCore
import SwiftUI

/// 快门。AI 放行后进入「就绪」：外圈青色常亮并呼吸，条件满足即自动拍摄；此时点快门 = 解除就绪。
struct ShutterButton: View {
    let model: CameraModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var armed: Bool { model.agent.isEnabled && model.agent.phase == .armed && model.agent.autoCaptureEnabled }
    private var busy: Bool { model.capturePending || model.state.isCapturing || model.isSaving }
    private var disabled: Bool { !armed && !model.canTakePhoto }

    var body: some View {
        Button(action: tap) { rings }
            .buttonStyle(.plain)
            .disabled(disabled)
            .opacity(disabled && !busy ? 0.4 : 1)
            .accessibilityLabel(armed ? "解除就绪" : "拍照并保存")
            .accessibilityValue(armed ? "AI 已就绪，条件满足时自动拍摄" : "")
            .accessibilityIdentifier(armed ? "camera.disarm" : "camera.shutter")
            .sensoryFeedback(.impact(weight: .medium), trigger: model.state.isCapturing)
            .sensoryFeedback(.selection, trigger: armed)
    }

    private func tap() {
        if armed { model.cancelAutoCapture() } else { model.takePhoto() }
    }

    private var rings: some View {
        ZStack {
            if armed {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                    let level = reduceMotion ? 1 : 0.55 + 0.45 * (0.5 - 0.5 * cos(phase * 2 * .pi))
                    Circle()
                        .stroke(Theme.Palette.accent.opacity(level), lineWidth: 3)
                        .shadow(color: Theme.Palette.accent.opacity(0.6 * level), radius: 8)
                }
                .frame(width: 78, height: 78)
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
