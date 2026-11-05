import Foundation
import Testing
@testable import CameraCore

@Test func adjustmentRequiresAnExplicitSafeSettingsPayload() throws {
    #expect(throws: (any Error).self) {
        try AgentDecision(action: .adjust, settings: nil, reason: "调整构图")
            .validate(against: testLimits())
    }
    #expect(throws: (any Error).self) {
        try AgentDecision(action: .adjust, settings: CameraSettings(zoom: 100), reason: "拉近主体")
            .validate(against: testLimits())
    }
    try AgentDecision(action: .adjust, settings: CameraSettings(ratio: .tall), reason: "突出纵向主体")
        .validate(against: testLimits())
}

@Test func holdCannotAccidentallyCarrySettingsToApply() throws {
    try AgentDecision(action: .hold, settings: nil, reason: "当前构图合适")
        .validate(against: testLimits())
    #expect(throws: (any Error).self) {
        try AgentDecision(action: .hold, settings: CameraSettings(), reason: "保持当前画面")
            .validate(against: testLimits())
    }
}

@Test func decisionsRequireANonemptyBoundedExplanation() throws {
    for reason in ["", " \n\t", String(repeating: "景", count: 301)] {
        #expect(throws: (any Error).self) {
            try AgentDecision(action: .hold, settings: nil, reason: reason)
                .validate(against: testLimits())
        }
    }
    try AgentDecision(action: .hold, settings: nil, reason: String(repeating: "景", count: 300))
        .validate(against: testLimits())
}

@Test func validModelJSONPreservesTheRequestedFrameAndManualExposure() throws {
    let payload = Data("""
        {"action":"adjust","settings":{"ratio":"9:16","zoom":2,"aperture":2.8,
        "iso":100,"shutterSeconds":0.01,"exposureBias":0},"reason":"突出人物"}
        """.utf8)
    let decision = try JSONDecoder().decode(AgentDecision.self, from: payload)
    try decision.validate(against: testLimits())
    #expect(decision.settings == CameraSettings(
        ratio: .tall, zoom: 2, aperture: 2.8, iso: 100, shutterSeconds: 0.01
    ))
    #expect(!decision.readyToCapture)
}

@Test func adjustingSettingsCannotAlsoAuthorizeAnImmediatePhoto() {
    #expect(throws: (any Error).self) {
        try AgentDecision(
            action: .adjust, settings: CameraSettings(), reason: "调整后再检查",
            readyToCapture: true
        ).validate(against: testLimits())
    }
}

@Test func onlyAConfirmedHoldMayAuthorizeCapture() throws {
    let payload = Data("""
        {"action":"hold","settings":null,"reason":"构图与曝光已稳定","readyToCapture":true}
        """.utf8)
    let decision = try JSONDecoder().decode(AgentDecision.self, from: payload)
    try decision.validate(against: testLimits())
    #expect(decision.readyToCapture)

    let encoded = try JSONEncoder().encode(decision)
    let restored = try JSONDecoder().decode(AgentDecision.self, from: encoded)
    #expect(restored.readyToCapture)
}
