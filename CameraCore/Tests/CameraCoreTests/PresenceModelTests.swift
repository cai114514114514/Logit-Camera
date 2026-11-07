import Testing
@testable import CameraCore

private let crop = NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)

private func run(_ animator: inout PresenceAnimator, _ input: PresenceInput, seconds: Double) -> PresenceFrame {
    var frame = animator.step(input, dt: 0)
    for _ in 0..<Int(seconds * 30) { frame = animator.step(input, dt: 1.0 / 30) }
    return frame
}

@Test func presenceObservingIsSlowAndDim() {
    var animator = PresenceAnimator()
    let frame = run(&animator, PresenceInput(phase: .scouting, readiness: 0, subject: nil, crop: crop), seconds: 1)
    #expect(abs(frame.auroraAngle - 55) < 1)
    #expect(frame.auroraOpacity == 0.55)
    #expect(frame.breathing == false)
}

@Test func presenceGazeFollowsSubject() {
    var animator = PresenceAnimator()
    let subject = NormalizedRect(x: 0.6, y: 0.3, width: 0.2, height: 0.2)
    let frame = run(&animator, PresenceInput(phase: .composing, readiness: 0.5, subject: subject, crop: crop), seconds: 1.5)
    #expect(abs(frame.gaze.x - 0.7) < 0.02)
    #expect(abs(frame.gaze.y - 0.4) < 0.02)
    #expect(frame.gradientCenter.x > 0.6)
}

@Test func presenceBreathesWhenReady() {
    var animator = PresenceAnimator()
    #expect(animator.step(PresenceInput(phase: .composing, readiness: 0.95, subject: nil, crop: crop), dt: 0.03).breathing)
    #expect(animator.step(PresenceInput(phase: .composing, readiness: 0.5, subject: nil, crop: crop), dt: 0.03).breathing == false)
}

@Test func presenceCollapsesOnCapture() {
    var animator = PresenceAnimator()
    let frame = animator.step(PresenceInput(phase: .capturing, readiness: 1, subject: nil, crop: crop, captureProgress: 1), dt: 0.03)
    #expect(frame.haloOpacity == 0)
    #expect(abs(frame.auroraScale - 0.96) < 1e-9)
}

@Test func presenceReduceMotionIsStatic() {
    var animator = PresenceAnimator()
    let input = PresenceInput(phase: .composing, readiness: 1, subject: nil, crop: crop, reduceMotion: true)
    let first = animator.step(input, dt: 0.03)
    let later = run(&animator, input, seconds: 1)
    #expect(first.auroraAngle == later.auroraAngle)
    #expect(later.breathing == false)
    #expect(later.gaze == NormalizedPoint(x: 0.5, y: 0.45))
}

@Test func presenceOffIsInvisible() {
    var animator = PresenceAnimator()
    let frame = animator.step(PresenceInput(phase: .off, readiness: 0, subject: nil, crop: crop), dt: 0.03)
    #expect(frame.auroraOpacity == 0)
    #expect(frame.haloOpacity == 0)
}
