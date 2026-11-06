import Testing
@testable import CameraCore

private func evaluate(_ plan: ShotPlan, _ m: SceneMeasurement, now: Double = 0,
                      placement: Double = 0, settled: Bool = true) -> TriggerReport {
    var evaluator = TriggerEvaluator(plan: plan)
    return evaluator.update(m, now: now, placementError: placement, exposureSettled: settled)
}

@Test func eyesOpenUsesSmallerEye() {
    let plan = samplePlan(triggers: [.eyesOpen(min: 0.6)])
    #expect(evaluate(plan, sampleMeasurement(subjects: [face(eyes: 0.5)], primary: 1)).allSatisfied == false)
    #expect(evaluate(plan, sampleMeasurement(subjects: [face(eyes: 0.7)], primary: 1)).allSatisfied)
}

@Test func horizonUsesAbsoluteAngle() {
    let plan = samplePlan(subject: .none, triggers: [.horizonLevel(maxDegrees: 1)])
    #expect(evaluate(plan, sampleMeasurement(horizon: -0.8)).allSatisfied)
    #expect(evaluate(plan, sampleMeasurement(horizon: -1.5)).allSatisfied == false)
}

@Test func missingHorizonFailsLevelCondition() {
    let plan = samplePlan(subject: .none, triggers: [.horizonLevel(maxDegrees: 1)])
    #expect(evaluate(plan, sampleMeasurement(horizon: nil)).allSatisfied == false)
}

@Test func sustainedRequiresHoldMs() {
    var evaluator = TriggerEvaluator(plan: samplePlan(holdMs: 200))
    let first = evaluator.update(sampleMeasurement(at: 0, subjects: [face()], primary: 1), now: 0,
                                 placementError: 0, exposureSettled: true)
    #expect(first.allSatisfied)
    #expect(first.sustained == false)
    let later = evaluator.update(sampleMeasurement(at: 0.21, subjects: [face()], primary: 1), now: 0.21,
                                 placementError: 0, exposureSettled: true)
    #expect(later.sustained)
}

@Test func singleFailingFrameResetsHold() {
    var evaluator = TriggerEvaluator(plan: samplePlan(holdMs: 200))
    _ = evaluator.update(sampleMeasurement(at: 0, subjects: [face()], primary: 1), now: 0, placementError: 0, exposureSettled: true)
    _ = evaluator.update(sampleMeasurement(at: 0.1, subjects: [face(eyes: 0.1)], primary: 1), now: 0.1, placementError: 0, exposureSettled: true)
    let report = evaluator.update(sampleMeasurement(at: 0.25, subjects: [face()], primary: 1), now: 0.25,
                                  placementError: 0, exposureSettled: true)
    #expect(report.allSatisfied)
    #expect(report.sustained == false)
}

@Test func armedPlanNeverFiresWithoutSubject() {
    var evaluator = TriggerEvaluator(plan: samplePlan(triggers: [.deviceStill(maxRadPerSec: 0.1)], holdMs: 0))
    let report = evaluator.update(sampleMeasurement(at: 0), now: 0, placementError: 0, exposureSettled: true)
    #expect(report.statuses.contains { $0.trigger == .subjectPresent && !$0.satisfied })
    #expect(report.sustained == false)
}

@Test func staleMeasurementSatisfiesNothing() {
    let plan = samplePlan(subject: .none, triggers: [.deviceStill(maxRadPerSec: 0.1)], holdMs: 0)
    let report = evaluate(plan, sampleMeasurement(at: 0), now: 0.4)
    #expect(report.statuses.allSatisfy { !$0.satisfied })
    #expect(report.sustained == false)
}

@Test func nearlyReadyAllowsOneCloseMiss() {
    let plan = samplePlan(subject: .none, triggers: [.deviceStill(maxRadPerSec: 0.1), .highlightsSafe(maxClip: 0.01)])
    #expect(evaluate(plan, sampleMeasurement(angularSpeed: 0.11)).nearlyReady)
    #expect(evaluate(plan, sampleMeasurement(angularSpeed: 0.13)).nearlyReady == false)
    #expect(evaluate(plan, sampleMeasurement(angularSpeed: 0.11, clipHigh: 0.011)).nearlyReady == false)
}

@Test func exposureSettledFollowsController() {
    let plan = samplePlan(subject: .none, triggers: [.exposureSettled])
    #expect(evaluate(plan, sampleMeasurement(), settled: false).allSatisfied == false)
    #expect(evaluate(plan, sampleMeasurement(), settled: true).allSatisfied)
}
