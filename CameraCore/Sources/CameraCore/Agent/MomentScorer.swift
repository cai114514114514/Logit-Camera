import Foundation

public struct MomentStatus: Sendable, Equatable {
    public let trigger: Trigger
    /// 数据可用（例如室内没有地平线时 horizonLevel 不可用，不参与计分）。
    public let available: Bool
    public let satisfied: Bool
    /// 0…1：满足为 1，否则 max(0, 1 + 余量)。
    public let score: Double

    public init(trigger: Trigger, available: Bool, satisfied: Bool, score: Double) {
        self.trigger = trigger
        self.available = available
        self.satisfied = satisfied
        self.score = score
    }
}

public struct MomentReport: Sendable, Equatable {
    public enum FireReason: String, Sendable, Equatable { case perfect, patience }

    public let statuses: [MomentStatus]
    /// 时机分 0…1。
    public let score: Double
    public let fireReady: Bool
    public let reason: FireReason?

    public init(statuses: [MomentStatus], score: Double, fireReady: Bool, reason: FireReason?) {
        self.statuses = statuses
        self.score = score
        self.fireReady = fireReady
        self.reason = reason
    }

    /// 关闭自动拍摄时使用：保留分数，不触发。
    public var withoutFire: MomentReport {
        MomentReport(statuses: statuses, score: score, fireReady: false, reason: nil)
    }
}

/// 时机评分（规格 §5.4）：时机信号是加分项，不是前提。
/// 完美（全部满足并持续 holdMs）立即拍；否则耐心 4 秒后拍下接近最近最高分的一刻。
public struct MomentScorer: Sendable {
    public static let patience: TimeInterval = 4
    public static let patienceFloor = 0.6
    public static let patienceRatio = 0.95
    public static let maxMeasurementAge: TimeInterval = 0.3
    public static let unsettledScore = 0.5

    public let signals: [Trigger]
    private let wantsSubject: Bool
    /// 方案要求人（脸或人体）：没有人时不拍。显著区域只是参考，缺失不影响。
    private let wantsPerson: Bool
    private let holdSeconds: Double
    private var startedAt: TimeInterval
    private var perfectSince: TimeInterval?
    private var lastUpdate: TimeInterval?
    private var window: [(time: TimeInterval, score: Double)] = []

    public init(plan: ShotPlan, startedAt: TimeInterval) {
        signals = plan.moment
        wantsSubject = plan.subject != .none
        wantsPerson = plan.subject == .face || plan.subject == .body
        holdSeconds = Double(plan.holdMs) / 1000
        self.startedAt = startedAt
    }

    /// 新方案、冷却结束、再拍一张时重新计时。
    public mutating func restart(at time: TimeInterval) {
        startedAt = time
        perfectSince = nil
        lastUpdate = nil
        window = []
    }

    public mutating func update(_ m: SceneMeasurement, now: TimeInterval,
                                placementError: Double, exposureSettled: Bool) -> MomentReport {
        let fresh = now - m.timestamp <= Self.maxMeasurementAge
        // 测量中断（超过 0.3 秒没有更新）时，「持续满足」重新计时。
        if let lastUpdate, now - lastUpdate > Self.maxMeasurementAge { perfectSince = nil }
        lastUpdate = now

        let statuses = signals.map { status(of: $0, m, placementError: placementError) }
        let available = statuses.filter(\.available)
        var score: Double
        if available.isEmpty {
            score = 1
        } else {
            let logSum = available.reduce(0.0) { $0 + log(max($1.score, 1e-6)) }
            score = exp(logSum / Double(available.count))
            if available.contains(where: { $0.score <= 0 }) { score = 0 }
        }
        if !exposureSettled { score *= Self.unsettledScore }
        if !fresh || (wantsPerson && m.primarySubject == nil) { score = 0 }

        window.append((now, score))
        window.removeAll { now - $0.time > Self.patience + 1e-9 }

        if score >= 0.999 {
            if perfectSince == nil { perfectSince = now }
        } else {
            perfectSince = nil
        }
        if let since = perfectSince, now - since >= holdSeconds - 1e-9 {
            return MomentReport(statuses: statuses, score: score, fireReady: true, reason: .perfect)
        }
        let best = window.map(\.score).max() ?? score
        if now - startedAt >= Self.patience - 1e-9, score >= Self.patienceFloor, score >= best * Self.patienceRatio - 1e-9 {
            return MomentReport(statuses: statuses, score: score, fireReady: true, reason: .patience)
        }
        return MomentReport(statuses: statuses, score: score, fireReady: false, reason: nil)
    }

    private func status(of trigger: Trigger, _ m: SceneMeasurement, placementError: Double) -> MomentStatus {
        let subject = m.primarySubject
        let margin: Double?
        switch trigger {
        case .subjectSharp(let minimum):
            let value = (wantsSubject ? m.sharpness.subject : nil) ?? m.sharpness.global
            margin = atLeast(value, minimum)
        case .eyesOpen(let minimum):
            margin = subject?.eyeOpenness.map { atLeast($0, minimum) }
        case .faceToward(let maxYaw):
            margin = subject?.yaw.map { atMost(abs($0), maxYaw) }
        case .horizonLevel(let maxDegrees):
            margin = m.horizonDegrees.map { atMost(abs($0), maxDegrees) }
        case .deviceStill(let maxSpeed):
            margin = atMost(m.deviceAngularSpeed, maxSpeed)
        case .subjectPlaced(let maxError):
            margin = wantsSubject && subject != nil ? atMost(placementError, maxError) : nil
        case .highlightsSafe(let maxClip):
            margin = atMost(m.luminance.clipHigh, maxClip)
        }
        guard let margin else { return MomentStatus(trigger: trigger, available: false, satisfied: false, score: 1) }
        let satisfied = margin >= 0
        return MomentStatus(trigger: trigger, available: true, satisfied: satisfied,
                            score: satisfied ? 1 : max(0, 1 + margin))
    }

    private func atLeast(_ value: Double, _ minimum: Double) -> Double {
        (value - minimum) / max(minimum, 0.01)
    }

    private func atMost(_ value: Double, _ maximum: Double) -> Double {
        (maximum - value) / max(maximum, 0.0001)
    }
}
