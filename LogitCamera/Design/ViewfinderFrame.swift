import SwiftUI

/// 取景框四角刻线。AI 开启时变为青色并缓慢呼吸；
/// `scanTick` 每次变化表示 Agent 刚截取了一帧，播放一次扫描线。
struct ViewfinderFrame: View {
    let aiActive: Bool
    let scanTick: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            // 关键帧闭包是 @Sendable，只捕获高度值而不是 GeometryProxy。
            let height = geometry.size.height
            ZStack(alignment: .top) {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !aiActive || reduceMotion)) { context in
                    CornerTicks(length: Theme.Metric.cornerTick)
                        .stroke(tickColor(at: context.date), style: StrokeStyle(lineWidth: 1.5, lineCap: .square))
                        .padding(10)
                }
                if aiActive && reduceMotion {
                    // 减少动态效果：角标闪亮一次代替扫描线。
                    CornerTicks(length: Theme.Metric.cornerTick)
                        .stroke(Theme.Palette.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .square))
                        .padding(10)
                        .keyframeAnimator(initialValue: Pulse(), trigger: scanTick) { content, value in
                            content.opacity(value.opacity)
                        } keyframes: { _ in
                            KeyframeTrack(\.opacity) {
                                MoveKeyframe(1)
                                LinearKeyframe(0, duration: 0.6)
                            }
                        }
                }
                if aiActive && !reduceMotion {
                    // 扫描线常驻于层级中，由关键帧在每次 tick 时从顶部扫到底部，结束后隐藏。
                    ScanLine()
                        .frame(height: 24)
                        .keyframeAnimator(initialValue: Scan(), trigger: scanTick) { content, value in
                            content
                                .offset(y: value.progress * height - 24)
                                .opacity(value.opacity)
                        } keyframes: { _ in
                            KeyframeTrack(\.progress) {
                                MoveKeyframe(0)
                                CubicKeyframe(1.02, duration: Theme.Motion.scanDuration)
                            }
                            KeyframeTrack(\.opacity) {
                                MoveKeyframe(1)
                                LinearKeyframe(1, duration: Theme.Motion.scanDuration - 0.1)
                                LinearKeyframe(0, duration: 0.1)
                            }
                        }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct Scan {
        var progress: CGFloat = 1.02
        var opacity: Double = 0
    }

    private struct Pulse {
        var opacity: Double = 0
    }

    private func tickColor(at date: Date) -> Color {
        guard aiActive else { return Color.white.opacity(0.4) }
        if reduceMotion { return Theme.Palette.accent.opacity(0.75) }
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Theme.Motion.breathPeriod)
            / Theme.Motion.breathPeriod
        // 0.35 ↔ 1.0 余弦呼吸：慢而连续，不闪烁。
        let level = 0.35 + 0.65 * (0.5 - 0.5 * cos(phase * 2 * .pi))
        return Theme.Palette.accent.opacity(level)
    }
}

/// 四个 L 形角标。
struct CornerTicks: Shape {
    let length: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let l = min(length, rect.width / 3, rect.height / 3)
        for (corner, dx, dy) in [(CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0),
                                 (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
                                 (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0),
                                 (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0)] {
            path.move(to: CGPoint(x: corner.x, y: corner.y + dy * l))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x + dx * l, y: corner.y))
        }
        return path
    }
}

/// 1pt 青色扫描线，上方带 24pt 渐隐尾迹。
private struct ScanLine: View {
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [Theme.Palette.accent.opacity(0), Theme.Palette.accent.opacity(0.22)],
                           startPoint: .top, endPoint: .bottom)
            Rectangle().fill(Theme.Palette.accent).frame(height: 1)
                .shadow(color: Theme.Palette.accent, radius: 4)
        }
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.3)
        ViewfinderFrame(aiActive: true, scanTick: 0)
    }
    .frame(width: 300, height: 400)
    .background(.black)
}
