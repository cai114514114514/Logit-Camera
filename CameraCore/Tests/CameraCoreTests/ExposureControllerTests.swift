import Foundation
import Testing
@testable import CameraCore

private func intent(ev: Double = 0, clip: Double = 0.01, floor: Double? = nil, iso: Double? = nil) -> ExposureIntent {
    ExposureIntent(meter: .subject, subjectEV: ev, highlightClipMax: clip, aperture: ApertureIntent(mode: .auto),
                   shutterFloor: floor, isoCeiling: iso)
}

private func state(bias: Double = 0, shutter: Double = 1.0 / 250, locked: Bool = false, iso: Double = 200) -> ExposureState {
    ExposureState(bias: bias, shutterSeconds: shutter, shutterLocked: locked, iso: iso, minISO: 50, minBias: -2, maxBias: 2)
}

private func scene(subjectMean: Double, clip: Double = 0) -> SceneMeasurement {
    var m = sampleMeasurement(subjects: [face()], primary: 1, clipHigh: clip)
    m.luminance.subjectMean = subjectMean
    return m
}

@Test func darkSubjectRaisesBias() {
    var controller = ExposureController()
    #expect(controller.step(scene(subjectMean: 0.2), intent: intent(), state: state()) == .setBias(0.1))
}

@Test func brightSubjectLowersBias() {
    var controller = ExposureController()
    #expect(controller.step(scene(subjectMean: 0.8), intent: intent(), state: state(bias: 0.5)) == .setBias(0.4))
}

@Test func deadbandHoldsSteady() {
    var controller = ExposureController()
    let onTarget = 0.46 * pow(2, 0.3 + 0.05)
    #expect(controller.step(scene(subjectMean: onTarget), intent: intent(ev: 0.3), state: state()) == .none)
}

@Test func highlightClipBlocksBrightening() {
    var controller = ExposureController()
    #expect(controller.step(scene(subjectMean: 0.2, clip: 0.02), intent: intent(clip: 0.01), state: state()) == .setBias(-0.1))
    #expect(controller.step(scene(subjectMean: 0.2, clip: 0.009), intent: intent(clip: 0.01), state: state()) == .none)
}

@Test func slowAutoShutterLocksFloor() {
    var controller = ExposureController()
    let command = controller.step(scene(subjectMean: 0.46), intent: intent(floor: 1.0 / 125, iso: 3200),
                                  state: state(shutter: 1.0 / 30))
    #expect(command == .lockShutter(seconds: 1.0 / 125))
}

@Test func releasesWhenBrightEnough() {
    var controller = ExposureController()
    let command = controller.step(scene(subjectMean: 0.46), intent: intent(floor: 1.0 / 125),
                                  state: state(shutter: 1.0 / 125, locked: true, iso: 55))
    #expect(command == .releaseShutter)
}

@Test func isoCeilingReleasesLockWithoutRelocking() {
    var controller = ExposureController()
    let floor = intent(floor: 1.0 / 125, iso: 1600)
    #expect(controller.step(scene(subjectMean: 0.46), intent: floor, state: state(shutter: 1.0 / 125, locked: true, iso: 1700))
            == .releaseShutter)
    #expect(controller.step(scene(subjectMean: 0.46), intent: floor, state: state(shutter: 1.0 / 30)) != .lockShutter(seconds: 1.0 / 125))
}

@Test func releasesLockWhenPlanHasNoFloor() {
    var controller = ExposureController()
    #expect(controller.step(scene(subjectMean: 0.46), intent: intent(), state: state(locked: true)) == .releaseShutter)
}

@Test func settledAfterThreeFrames() {
    var controller = ExposureController()
    let onTarget = scene(subjectMean: 0.46)
    for _ in 0..<2 { _ = controller.step(onTarget, intent: intent(), state: state()) }
    #expect(controller.settled == false)
    _ = controller.step(onTarget, intent: intent(), state: state())
    #expect(controller.settled)
    _ = controller.step(scene(subjectMean: 0.2), intent: intent(), state: state())
    #expect(controller.settled == false)
}

@Test func biasAtLimitCountsAsSettled() {
    var controller = ExposureController()
    for _ in 0..<3 {
        #expect(controller.step(scene(subjectMean: 0.05), intent: intent(), state: state(bias: 2)) == .none)
    }
    #expect(controller.settled)
}
