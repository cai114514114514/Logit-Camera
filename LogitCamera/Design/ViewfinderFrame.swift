import CameraCore
import SwiftUI

/// AI 关闭时的取景框四角白色刻线。AI 开启时由极光边缘（PresenceLayer）取代。
struct ViewfinderFrame: View {
    let aiActive: Bool

    var body: some View {
        GeometryReader { geometry in
            if !aiActive {
                CornerTicks(length: Theme.Metric.cornerTick)
                    .stroke(Color.white.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, lineCap: .square))
                    .frame(width: geometry.size.width - 20, height: geometry.size.height - 20)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.3), value: aiActive)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
