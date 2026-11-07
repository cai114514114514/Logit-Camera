import Foundation

public struct PresenceInput: Sendable, Equatable {
    public var phase: AgentPhase
    /// 时机分 0…1。
    public var readiness: Double
    /// 主体框（取景全画幅归一化坐标）。
    public var subject: NormalizedRect?
    public var crop: NormalizedRect
    public var reduceMotion: Bool
    /// 拍下动画的进度 0…1（拍下后 0.3 秒内），nil 表示不在拍。
    public var captureProgress: Double?

    public init(phase: AgentPhase, readiness: Double, subject: NormalizedRect?, crop: NormalizedRect,
                reduceMotion: Bool = false, captureProgress: Double? = nil) {
        self.phase = phase
        self.readiness = readiness
        self.subject = subject
        self.crop = crop
        self.reduceMotion = reduceMotion
        self.captureProgress = captureProgress
    }
}

/// 一帧光效参数。
public struct PresenceFrame: Sendable, Equatable {
    public var auroraOpacity: Double
    /// 描边宽度（pt）。
    public var auroraWidth: Double
    /// 角向渐变的起始角（度）。
    public var auroraAngle: Double
    /// 角向渐变的中心（全画幅归一化坐标）：认出主体后偏向主体，使最亮的一段落在那一侧。
    public var gradientCenter: NormalizedPoint
    /// 拍下时极光收拢的比例（1 = 原尺寸）。
    public var auroraScale: Double
    public var haloOpacity: Double
    /// 光晕半径（取景短边的比例）。
    public var haloRadius: Double
    /// AI 的视线点（全画幅归一化坐标）。
    public var gaze: NormalizedPoint
    public var breathing: Bool
}

/// 光效动画器（规格 §2.1、§2.2）：输入 AI 状态与帧间隔，输出极光与光晕的参数。
/// 角度与视线点需要积分（速度会变），所以带少量状态。
public struct PresenceAnimator: Sendable {
    public static let observeSpeed = 55.0
    public static let breathPeriod = 0.9

    private var angle = 0.0
    private var time = 0.0
    private var gaze: NormalizedPoint?

    public init() {}

    public mutating func step(_ input: PresenceInput, dt: TimeInterval) -> PresenceFrame {
        let dt = min(max(dt, 0), 0.1)
        time += dt
        let r = min(max(input.readiness, 0), 1)
        let working = [.planning, .composing].contains(input.phase)

        var opacity: Double, width: Double, speed: Double, haloOpacity: Double
        switch input.phase {
        case .off:
            opacity = 0; width = 3; speed = 0; haloOpacity = 0
        case .scouting:
            opacity = 0.55; width = 3; speed = Self.observeSpeed; haloOpacity = 0.18
        case .planning, .composing:
            opacity = 0.55 + 0.45 * r; width = 3 + 2.5 * r; speed = Self.observeSpeed + 120 * r
            haloOpacity = 0.14 + 0.18 * r
        case .capturing:
            opacity = 1; width = 5.5; speed = Self.observeSpeed + 120; haloOpacity = 0.32
        case .cooldown, .paused:
            opacity = 0.35; width = 2.5; speed = 20; haloOpacity = 0.08
        }

        let breathing = working && r >= 0.9 && !input.reduceMotion
        if breathing {
            let wave = 0.5 - 0.5 * cos(time * 2 * .pi / Self.breathPeriod)
            opacity *= 0.75 + 0.25 * wave
            width *= 0.85 + 0.15 * wave
        }
        if !input.reduceMotion { angle = (angle + speed * dt).truncatingRemainder(dividingBy: 360) }

        let target: NormalizedPoint
        if let subject = input.subject {
            target = subject.center
        } else if input.reduceMotion {
            target = NormalizedPoint(x: 0.5, y: 0.45)
        } else {
            target = NormalizedPoint(x: 0.5 + 0.2 * sin(0.6 * time), y: 0.45 + 0.12 * sin(0.43 * time))
        }
        let follow = input.reduceMotion ? 1 : 1 - exp(-dt * 6)
        let previous = gaze ?? target
        let current = NormalizedPoint(x: previous.x + (target.x - previous.x) * follow,
                                      y: previous.y + (target.y - previous.y) * follow)
        gaze = current

        let center = input.crop.center
        let bias = input.subject == nil ? 0 : 0.8
        let gradientCenter = NormalizedPoint(x: center.x + (current.x - center.x) * bias,
                                             y: center.y + (current.y - center.y) * bias)
        var radius = 0.30 + 0.10 * r
        var scale = 1.0
        if let p = input.captureProgress {
            let collapse = p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
            scale = 1 - 0.04 * collapse
            radius *= 1 - 0.8 * collapse
            haloOpacity *= 1 - collapse
            opacity = min(1, opacity + 0.3 * (1 - collapse)) * (1 - 0.6 * collapse)
        }
        return PresenceFrame(auroraOpacity: opacity, auroraWidth: width, auroraAngle: angle, gradientCenter: gradientCenter,
                             auroraScale: scale, haloOpacity: min(haloOpacity, 0.32), haloRadius: radius,
                             gaze: current, breathing: breathing)
    }
}
