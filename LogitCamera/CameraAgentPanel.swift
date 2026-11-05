import SwiftUI

struct CameraAgentPanel: View {
    let model: CameraModel

    private var agent: CameraAgent { model.agent }
    private let steps = ["观察", "调参", "复核", "拍摄"]

    var body: some View {
        VStack(spacing: 10) {
            summary
            autoCaptureControls
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 22)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 22).fill(.black.opacity(0.3))
                }
                .allowsHitTesting(false)
        }
        .overlay {
            AgentGlowBorder(isActive: agent.isEnabled, cornerRadius: 22)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            stepTrack

            if !agent.changes.isEmpty {
                LazyVGrid(columns: parameterColumns, alignment: .leading, spacing: 6) {
                    ForEach(agent.changes) { change in
                        parameterChange(change)
                    }
                }
            }

            if !agent.reason.isEmpty {
                Text(agent.reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .allowsHitTesting(false)
        // Keep one stable accessibility element for status; controls stay separate.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibleStatus)
        .accessibilityValue("第 \(agent.round) 轮")
        .accessibilityIdentifier("camera.agent")
    }

    private var parameterColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 6), count: min(4, agent.changes.count))
    }

    private var accessibleStatus: String {
        let changes = agent.changes.map { "\($0.title)，\($0.before) 到 \($0.after)" }
        return (["DeepSeek", agent.status, agent.reason] + changes).joined(separator: "。")
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkles")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(
                    LinearGradient(colors: [.cyan, .white, .pink],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .frame(width: 28, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text("DeepSeek")
                    .font(.system(size: 14, weight: .bold))
                Text(agent.status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 4) {
                Text("第 \(agent.round) 轮")
                if agent.confirmationCount > 0 {
                    Label("复核 \(agent.confirmationCount) 次", systemImage: "checkmark.shield")
                }
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
            .fixedSize()
        }
    }

    private var stepTrack: some View {
        HStack(spacing: 4) {
            ForEach(steps.indices, id: \.self) { index in
                HStack(spacing: 4) {
                    Image(systemName: stepSymbol(at: index))
                        .font(.system(size: 8, weight: .bold))
                    Text(steps[index])
                        .font(.system(size: 10, weight: .semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 22)
                .foregroundStyle(activeStep == index ? .white : .white.opacity(0.45))
                .background(activeStep == index ? .white.opacity(0.14) : .clear, in: Capsule())
            }
        }
    }

    private var activeStep: Int? {
        switch agent.stage {
        case .observing, .thinking: 0
        case .applying: 1
        case .verifying, .ready: 2
        case .countdown: 3
        case .paused: nil
        }
    }

    private func stepSymbol(at index: Int) -> String {
        guard let activeStep else { return "circle" }
        if index < activeStep || (index == 2 && agent.stage == .ready) {
            return "checkmark"
        }
        return index == activeStep ? "circle.fill" : "circle"
    }

    private func parameterChange(_ change: AgentParameterChange) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(change.title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))

            Text(change.before)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))

            HStack(spacing: 3) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.cyan)
                Text(change.after)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private var autoCaptureControls: some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(get: { agent.autoCaptureEnabled }, set: model.setAutoCapture)) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("自动拍摄")
                        .font(.system(size: 12, weight: .semibold))
                    Text(agent.autoCaptureEnabled ? "复核通过后倒计时" : "由你按下快门")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .toggleStyle(.switch)
            .tint(.yellow)
            .frame(minHeight: 44)
            .accessibilityIdentifier("camera.autoCapture")

            if agent.autoCaptureEnabled && !agent.captureArmed {
                Button(action: model.armAutoCapture) {
                    Label("再拍一张", systemImage: "camera")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)
                        .foregroundStyle(.black)
                        .background(.yellow, in: Capsule())
                }
                .disabled(model.state.phase != .ready || model.isSaving || model.capturePending)
                .accessibilityIdentifier("camera.rearm")
            }
        }
    }
}

struct CameraCaptureCountdown: View {
    let countdown: Int
    let onCancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 2) {
                Text("复核通过 · 即将拍摄")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(countdown)")
                    .font(.system(size: 100, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: countdown)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.75), radius: 14, y: 3)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("自动拍摄倒计时")
            .accessibilityValue("\(countdown) 秒")
            .accessibilityIdentifier("camera.countdown")

            Button(action: onCancel) {
                Label("取消拍摄", systemImage: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 20)
                    .frame(minHeight: 44)
                    .foregroundStyle(.white)
                    .background(.black.opacity(0.7), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.2), lineWidth: 1))
            }
            .accessibilityIdentifier("camera.cancelCapture")
        }
    }
}

private struct AgentGlowBorder: View {
    let isActive: Bool
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let colors: [Color] = [.cyan, .blue, .purple, .pink, .orange, .yellow, .cyan]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !isActive)) { context in
            // One slow orbit gives a continuous glow without pulsing or flashing.
            let phase = reduceMotion ? 35 : context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 12) / 12 * 360
            let gradient = AngularGradient(colors: colors, center: .center,
                                           startAngle: .degrees(phase), endAngle: .degrees(phase + 360))
            let shape = RoundedRectangle(cornerRadius: cornerRadius)

            ZStack {
                if isActive {
                    shape.stroke(gradient, lineWidth: 7).blur(radius: 10).opacity(0.65)
                    shape.stroke(gradient, lineWidth: 3).blur(radius: 3).opacity(0.75)
                    shape.stroke(gradient, lineWidth: 1.3)
                } else {
                    shape.stroke(.white.opacity(0.18), lineWidth: 1)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
