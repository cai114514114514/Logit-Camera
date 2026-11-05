import Testing
@testable import CameraCore

@Test func oneConfirmationCannotStartCaptureButTwoConsecutiveConfirmationsCan() {
    var readiness = CaptureReadiness()
    #expect(readiness.confirmations == 0)
    let first = readiness.observe(confirmed: true, stable: true, hardwareReady: true)
    #expect(!first)
    #expect(readiness.confirmations == 1)
    let second = readiness.observe(confirmed: true, stable: true, hardwareReady: true)
    #expect(second)
    #expect(readiness.confirmations == 2)
    let third = readiness.observe(confirmed: true, stable: true, hardwareReady: true)
    #expect(third)
    #expect(readiness.confirmations == 2)
}

@Test func anyMissingCaptureConditionBreaksTheConsecutiveConfirmationSequence() {
    let invalidFrames = [
        (confirmed: false, stable: true, hardwareReady: true),
        (confirmed: true, stable: false, hardwareReady: true),
        (confirmed: true, stable: true, hardwareReady: false)
    ]

    for frame in invalidFrames {
        var readiness = CaptureReadiness()
        let first = readiness.observe(confirmed: true, stable: true, hardwareReady: true)
        #expect(!first)
        let interrupted = readiness.observe(
            confirmed: frame.confirmed, stable: frame.stable, hardwareReady: frame.hardwareReady
        )
        #expect(!interrupted)
        #expect(readiness.confirmations == 0)
        let firstAfterInterruption = readiness.observe(confirmed: true, stable: true, hardwareReady: true)
        #expect(!firstAfterInterruption)
        let secondAfterInterruption = readiness.observe(confirmed: true, stable: true, hardwareReady: true)
        #expect(secondAfterInterruption)
    }
}

@Test func resettingAnAlreadyReadyCaptureRequiresTwoFreshConfirmations() {
    var readiness = CaptureReadiness()
    let first = readiness.observe(confirmed: true, stable: true, hardwareReady: true)
    #expect(!first)
    let second = readiness.observe(confirmed: true, stable: true, hardwareReady: true)
    #expect(second)

    readiness.reset()
    #expect(readiness.confirmations == 0)
    let firstAfterReset = readiness.observe(confirmed: true, stable: true, hardwareReady: true)
    #expect(!firstAfterReset)
    let secondAfterReset = readiness.observe(confirmed: true, stable: true, hardwareReady: true)
    #expect(secondAfterReset)
}
