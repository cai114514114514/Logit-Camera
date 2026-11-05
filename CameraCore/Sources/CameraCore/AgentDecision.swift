import Foundation

public enum AgentAction: String, Codable, Sendable {
    case adjust
    case hold
}

public struct AgentDecision: Codable, Sendable {
    public var action: AgentAction
    public var settings: CameraSettings?
    public var reason: String
    public var readyToCapture: Bool

    public init(
        action: AgentAction,
        settings: CameraSettings?,
        reason: String,
        readyToCapture: Bool = false
    ) {
        self.action = action
        self.settings = settings
        self.reason = reason
        self.readyToCapture = readyToCapture
    }

    public func validate(against limits: CameraLimits) throws {
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              reason.count <= 300 else {
            throw CameraValidationError.invalidReason
        }

        switch action {
        case .adjust:
            guard !readyToCapture else { throw CameraValidationError.captureDuringAdjustment }
            guard let settings else { throw CameraValidationError.missingSettings }
            try settings.validate(against: limits)
        case .hold:
            guard settings == nil else { throw CameraValidationError.unexpectedSettings }
        }
    }
}
