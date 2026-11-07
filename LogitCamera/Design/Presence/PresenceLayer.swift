import CameraCore
import SwiftUI

/// 极光与光晕的配色：品牌青为主，流动中带少量蓝绿（规格 §1）。
enum AuroraPalette {
    static let colors: [Color] = [
        Theme.Palette.accent,
        Color(red: 0x2F / 255, green: 0xD6 / 255, blue: 0xC9 / 255),
        Color(red: 0x7A / 255, green: 0xA8 / 255, blue: 0xFF / 255),
        Color(red: 0x8E / 255, green: 0xF7 / 255, blue: 0xDC / 255),
        Theme.Palette.accent
    ]
}

/// 帧间积分的状态放在引用类型里：TimelineView 每帧调用，不触发 SwiftUI 重新计算。
@MainActor
final class PresenceEngine {
    private var animator = PresenceAnimator()
    private var last: Date?
    private var capturingSince: Date?

    func frame(_ input: PresenceInput, at date: Date) -> PresenceFrame {
        var input = input
        if input.phase == .capturing {
            let since = capturingSince ?? date
            capturingSince = since
            input.captureProgress = min(1, date.timeIntervalSince(since) / 0.3)
        } else {
            capturingSince = nil
        }
        let dt = last.map { date.timeIntervalSince($0) } ?? 0
        last = date
        return animator.step(input, dt: dt)
    }
}

/// AI 的光：画面里的呼吸光晕（AI 在看哪里）+ 构图框边缘的青色极光（AI 正在工作）。
/// 只在 AI 开启时渲染；不参与点按与无障碍。
struct PresenceLayer: View {
    let phase: AgentPhase
    let readiness: Double
    let subject: CameraCore.NormalizedRect?
    let crop: CameraCore.NormalizedRect
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var engine = PresenceEngine()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: phase == .off)) { context in
            let frame = engine.frame(PresenceInput(phase: phase, readiness: readiness, subject: subject, crop: crop,
                                                   reduceMotion: reduceMotion), at: context.date)
            GeometryReader { geometry in
                ZStack {
                    AttentionHalo(frame: frame, size: geometry.size)
                    AuroraEdge(frame: frame, rect: rect(crop, in: geometry.size), size: geometry.size)
                }
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : nil, value: phase)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func rect(_ r: CameraCore.NormalizedRect, in size: CGSize) -> CGRect {
        CGRect(x: r.x * size.width, y: r.y * size.height, width: r.width * size.width, height: r.height * size.height)
    }
}

/// 构图框边缘的极光：一条锐利描边 + 一层模糊光晕，角向渐变的中心偏向 AI 的视线。
struct AuroraEdge: View {
    let frame: PresenceFrame
    let rect: CGRect
    let size: CGSize

    var body: some View {
        let gradient = AngularGradient(colors: AuroraPalette.colors,
                                       center: UnitPoint(x: frame.gradientCenter.x, y: frame.gradientCenter.y),
                                       angle: .degrees(frame.auroraAngle))
        let inset = rect.insetBy(dx: frame.auroraWidth / 2, dy: frame.auroraWidth / 2)
        let shape = Path(roundedRect: inset, cornerRadius: 4)
        ZStack {
            shape.stroke(gradient, lineWidth: frame.auroraWidth * 4)
                .blur(radius: 14)
                .opacity(0.55)
            shape.stroke(gradient, lineWidth: frame.auroraWidth)
        }
        .frame(width: size.width, height: size.height)
        .scaleEffect(frame.auroraScale, anchor: UnitPoint(x: rect.midX / max(size.width, 1), y: rect.midY / max(size.height, 1)))
        .opacity(frame.auroraOpacity)
    }
}

/// AI 的视线：一团淡青色的径向光晕（screen 混合）+ 四周轻微压暗。
struct AttentionHalo: View {
    let frame: PresenceFrame
    let size: CGSize

    var body: some View {
        let center = UnitPoint(x: frame.gaze.x, y: frame.gaze.y)
        let radius = frame.haloRadius * min(size.width, size.height)
        let o = frame.haloOpacity
        ZStack {
            Rectangle().fill(RadialGradient(stops: [
                .init(color: .black.opacity(0), location: 0.45),
                .init(color: .black.opacity(o * 0.9), location: 1)
            ], center: center, startRadius: radius * 0.6, endRadius: max(size.width, size.height)))
            Rectangle().fill(RadialGradient(stops: [
                .init(color: Theme.Palette.accent.opacity(o), location: 0),
                .init(color: Theme.Palette.accent.opacity(o * 0.35), location: 0.5),
                .init(color: Theme.Palette.accent.opacity(0), location: 1)
            ], center: center, startRadius: 0, endRadius: max(radius, 1)))
            .blendMode(.screen)
        }
        .frame(width: size.width, height: size.height)
    }
}
