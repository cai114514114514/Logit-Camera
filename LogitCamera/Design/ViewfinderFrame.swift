import SwiftUI

/// 取景框四角刻线。AI 开启时变为青色并缓慢呼吸；
/// `scanTick` 每次变化表示 Agent 刚截取了一帧，播放一次扫描线。
struct ViewfinderFrame: View {
    let aiActive: Bool
    let scanTick: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scanProgress: CGFloat = 1
    @State private var flash = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !aiActive || reduceMotion)) { context in
                    CornerTicks(length: Theme.Metric.cornerTick)
                        .stroke(tickColor(at: context.date), style: StrokeStyle(lineWidth: 1.5, lineCap: .square))
                        .padding(10)
                }
                if !reduceMotion && scanProgress < 1 {
                    ScanLine()
                        .frame(height: 24)
                        .offset(y: scanProgress * geometry.size.height - 24)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: scanTick) { _, _ in
            guard aiActive else { return }
            if reduceMotion {
                flash = true
                withAnimation(.easeOut(duration: 0.6)) { flash = false }
            } else {
                scanProgress = 0
                withAnimation(.easeInOut(duration: Theme.Motion.scanDuration)) { scanProgress = 1.02 }
            }
        }
    }

    private func tickColor(at date: Date) -> Color {
        guard aiActive else { return Theme.Palette.hairline.opacity(2.2) }
        if reduceMotion { return flash ? Theme.Palette.accent : Theme.Palette.accent.opacity(0.75) }
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
