import Testing
@testable import CameraCore

@Test func originDistinguishesAutomaticUserAndAgentValues() {
    #expect(ValueOrigin.of(isManual: false, agentOwned: true) == .automatic)
    #expect(ValueOrigin.of(isManual: false, agentOwned: false) == .automatic)
    #expect(ValueOrigin.of(isManual: true, agentOwned: true) == .ai)
    #expect(ValueOrigin.of(isManual: true, agentOwned: false) == .user)
}
