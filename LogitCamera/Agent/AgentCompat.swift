import CameraCore
import Foundation

/// 过渡用：旧界面读取的阶段与字段。Task 13 改写界面后删除。
enum AgentStage: String, Sendable {
    case observing, thinking, applying, verifying, ready, countdown, paused
}

extension AgentController {
    var stage: AgentStage {
        switch phase {
        case .scouting: .observing
        case .planning, .reviewing: .thinking
        case .tracking: .verifying
        case .armed, .capturing: .ready
        case .cooldown, .paused, .off: .paused
        }
    }
    var round: Int { calls }
    var confirmationCount: Int { phase == .armed ? 2 : (phase == .reviewing ? 1 : 0) }
    var changes: [ParameterDelta] { [] }
    var adjustmentID: UUID? { isDefaultPlan ? nil : plan?.id }
    var countdown: Int? { nil }
    var captureArmed: Bool { phase != .cooldown }
}
