import Foundation

public struct TriggerStatus: Sendable, Equatable {
    public let trigger: Trigger
    public let satisfied: Bool
    /// 按阈值归一的余量：≥ 0 满足，< 0 未满足（-0.2 表示还差 20%）。
    public let margin: Double
}

public struct TriggerReport: Sendable, Equatable {
    public let statuses: [TriggerStatus]
    public let allSatisfied: Bool
    /// 全部满足且已持续 holdMs。
    public let sustained: Bool
    /// 全部满足，或只有一项未满足且差距不超过 20%：可以请评审放行。
    public let nearlyReady: Bool

    public init(statuses: [TriggerStatus], allSatisfied: Bool, sustained: Bool, nearlyReady: Bool) {
        self.statuses = statuses
        self.allSatisfied = allSatisfied
        self.sustained = sustained
        self.nearlyReady = nearlyReady
    }
}

/// 逐帧判定拍摄条件。测量超过 0.3 秒即视为过期，不满足任何条件。
public struct TriggerEvaluator: Sendable {
    public static let maxMeasurementAge: TimeInterval = 0.3

    public let triggers: [Trigger]
    private let holdSeconds: Double
    private let usesSubject: Bool
    private var satisfiedSince: TimeInterval?

    public init(plan: ShotPlan) {
        usesSubject = plan.subject != .none
        var list = plan.triggers
        if usesSubject && !list.contains(.subjectPresent) { list.insert(.subjectPresent, at: 0) }
        triggers = list
        holdSeconds = Double(plan.holdMs) / 1000
    }

    public mutating func update(_ m: SceneMeasurement, now: TimeInterval,
                                placementError: Double, exposureSettled: Bool) -> TriggerReport {
        let fresh = now - m.timestamp <= Self.maxMeasurementAge
        let statuses = triggers.map { trigger -> TriggerStatus in
            let margin = fresh ? margin(of: trigger, m, placementError: placementError, settled: exposureSettled) : -1
            return TriggerStatus(trigger: trigger, satisfied: margin >= 0, margin: margin)
        }
        let allSatisfied = statuses.allSatisfy(\.satisfied)
        if allSatisfied {
            if satisfiedSince == nil { satisfiedSince = now }
        } else {
            satisfiedSince = nil
        }
        let sustained = allSatisfied && now - (satisfiedSince ?? now) >= holdSeconds - 1e-9
        let misses = statuses.filter { !$0.satisfied }
        let nearlyReady = misses.isEmpty || (misses.count == 1 && misses[0].margin >= -0.2)
        return TriggerReport(statuses: statuses, allSatisfied: allSatisfied, sustained: sustained, nearlyReady: nearlyReady)
    }

    public mutating func reset() { satisfiedSince = nil }

    private func margin(of trigger: Trigger, _ m: SceneMeasurement, placementError: Double, settled: Bool) -> Double {
        let subject = m.primarySubject
        switch trigger {
        case .subjectSharp(let minimum):
            let value = (usesSubject ? m.sharpness.subject : nil) ?? m.sharpness.global
            return atLeast(value, minimum)
        case .eyesOpen(let minimum):
            guard let eyes = subject?.eyeOpenness else { return -1 }
            return atLeast(eyes, minimum)
        case .faceToward(let maxYaw):
            guard let yaw = subject?.yaw else { return -1 }
            return atMost(abs(yaw), maxYaw)
        case .horizonLevel(let maxDegrees):
            guard let horizon = m.horizonDegrees else { return -1 }
            return atMost(abs(horizon), maxDegrees)
        case .deviceStill(let maxSpeed):
            return atMost(m.deviceAngularSpeed, maxSpeed)
        case .subjectPlaced(let maxError):
            return atMost(placementError, maxError)
        case .highlightsSafe(let maxClip):
            return atMost(m.luminance.clipHigh, maxClip)
        case .exposureSettled:
            return settled ? 0 : -1
        case .subjectPresent:
            return subject == nil ? -1 : 0
        }
    }

    private func atLeast(_ value: Double, _ minimum: Double) -> Double {
        (value - minimum) / max(minimum, 0.01)
    }

    private func atMost(_ value: Double, _ maximum: Double) -> Double {
        (maximum - value) / max(maximum, 0.0001)
    }
}
