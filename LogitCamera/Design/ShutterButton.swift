import SwiftUI

/// 快门。自动拍摄倒计时时，外圈变成 3 秒青色进度环，按钮变为「取消拍摄」。
struct ShutterButton: View {
    let model: CameraModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: Double = 0

    private var countdown: Int? {
        model.agent.stage == .countdown ? model.agent.countdown : nil
    }

    private var busy: Bool { model.capturePending || model.state.isCapturing || model.isSaving }
    private var disabled: Bool { countdown == nil && !model.canTakePhoto }

    private func tap() {
        if countdown == nil { model.takePhoto() } else { model.cancelAutoCapture() }
    }

    private var button: some View {
        Button(action: tap) { rings }
            .buttonStyle(.plain)
            .disabled(disabled)
            .opacity(disabled && !busy ? 0.4 : 1)
            .accessibilityLabel(countdown == nil ? "拍照并保存" : "取消拍摄")
            .accessibilityValue(countdown.map { "\($0) 秒后自动拍摄" } ?? "")
            .accessibilityIdentifier(countdown == nil ? "camera.shutter" : "camera.cancelCapture")
    }

    private var rings: some View {
        ZStack {
            Circle().stroke(Theme.Palette.ink, lineWidth: 2).frame(width: 78, height: 78)
            if countdown != nil {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Theme.Palette.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 78, height: 78)
                    .shadow(color: Theme.Palette.accent.opacity(0.6), radius: 6)
                Circle().fill(Color.white.opacity(0.1)).frame(width: 64, height: 64)
            } else {
                let size: CGFloat = busy ? 54 : 64
                Circle().fill(Color.white).frame(width: size, height: size)
                    .animation(.snappy(duration: 0.15), value: busy)
                if busy { ProgressView().tint(.black) }
            }
        }
        .frame(width: 84, height: 84)
        .contentShape(Circle())
    }

    private func countdownLabel(_ value: Int) -> some View {
        VStack(spacing: -2) {
            Text("\(value)")
                .font(Theme.Typeface.countdown)
                .contentTransition(.numericText(countsDown: true))
            Text("取消").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.Palette.inkSecondary)
        }
        .foregroundStyle(Theme.Palette.accent)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("自动拍摄倒计时")
        .accessibilityValue("\(value) 秒")
        .accessibilityIdentifier("camera.countdown")
    }

    var body: some View {
        ZStack {
            button
            if let countdown { countdownLabel(countdown) }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: countdown)
        .sensoryFeedback(.impact(weight: .medium), trigger: model.state.isCapturing)
        .sensoryFeedback(.selection, trigger: countdown)
        .onChange(of: countdown, initial: true) { _, value in
            guard let value else { progress = 0; return }
            // 3 → 1/3、2 → 2/3、1 → 1：每秒线性走完一段，与真实倒计时同步。
            withAnimation(reduceMotion ? nil : .linear(duration: 1)) { progress = Double(4 - value) / 3 }
        }
    }
}
