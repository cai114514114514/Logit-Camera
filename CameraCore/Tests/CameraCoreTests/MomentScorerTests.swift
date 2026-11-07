import Testing
@testable import CameraCore

private func scorer(_ plan: ShotPlan, start: Double = 0) -> MomentScorer { MomentScorer(plan: plan, startedAt: start) }

@Test func eyesOpenUsesSmallerEye() {
    var s = scorer(samplePlan(moment: [.eyesOpen(min: 0.6)]))
    let closed = s.update(sampleMeasurement(subjects: [face(eyes: 0.5)], primary: 1), now: 0, placementError: 0, exposureSettled: true)
    #expect(closed.statuses[0].satisfied == false)
    #expect(abs(closed.statuses[0].score - (1 - 0.1 / 0.6)) < 1e-9)
}

@Test func missingHorizonIsNeutral() {
    var s = scorer(samplePlan(subject: .none, moment: [.horizonLevel(maxDegrees: 5)]))
    let first = s.update(sampleMeasurement(at: 0, horizon: nil), now: 0, placementError: 0, exposureSettled: true)
    #expect(first.statuses[0].available == false)
    #expect(first.score == 1)
    let later = s.update(sampleMeasurement(at: 0.2, horizon: nil), now: 0.2, placementError: 0, exposureSettled: true)
    #expect(later.fireReady)
    #expect(later.reason == .perfect)
}

@Test func geometricMeanOfScores() {
    // deviceStill 满足（1），highlightsSafe 超出 36%（0.64）→ √0.64 = 0.8
    var s = scorer(samplePlan(subject: .none, moment: [.deviceStill(maxRadPerSec: 0.1), .highlightsSafe(maxClip: 0.01)]))
    let report = s.update(sampleMeasurement(clipHigh: 0.0136), now: 0, placementError: 0, exposureSettled: true)
    #expect(abs(report.score - 0.8) < 1e-6)
}

@Test func missingSubjectZeroesScore() {
    var s = scorer(samplePlan(subject: .face, moment: [.deviceStill(maxRadPerSec: 0.1)]), start: -10)
    let report = s.update(sampleMeasurement(subjects: []), now: 0, placementError: 0, exposureSettled: true)
    #expect(report.score == 0)
    #expect(report.fireReady == false)
}

@Test func staleMeasurementZeroes() {
    var s = scorer(samplePlan(subject: .none, moment: []), start: -10)
    let report = s.update(sampleMeasurement(at: 0), now: 0.5, placementError: 0, exposureSettled: true)
    #expect(report.score == 0)
    #expect(report.fireReady == false)
}

@Test func perfectNeedsHold() {
    var s = scorer(samplePlan(subject: .none, moment: [.deviceStill(maxRadPerSec: 0.1)], holdMs: 200))
    #expect(s.update(sampleMeasurement(at: 0), now: 0, placementError: 0, exposureSettled: true).fireReady == false)
    #expect(s.update(sampleMeasurement(at: 0.1), now: 0.1, placementError: 0, exposureSettled: true).fireReady == false)
    #expect(s.update(sampleMeasurement(at: 0.2), now: 0.2, placementError: 0, exposureSettled: true).fireReady)
}

/// 用 deviceStill 的余量制造指定分数：分数 = 1 + (0.1 − speed) / 0.1。
private func measurement(score: Double, at time: Double) -> SceneMeasurement {
    sampleMeasurement(at: time, angularSpeed: 0.1 + (1 - score) * 0.1)
}

@Test func patienceFiresNearBest() {
    var s = scorer(samplePlan(subject: .none, moment: [.deviceStill(maxRadPerSec: 0.1)]))
    var t = 0.0
    while t < 3.95 {
        let score = abs(t - 1) < 0.01 ? 0.75 : 0.7
        #expect(s.update(measurement(score: score, at: t), now: t, placementError: 0, exposureSettled: true).fireReady == false)
        t += 0.1
    }
    var low = s
    let miss = low.update(measurement(score: 0.65, at: 4.0), now: 4.0, placementError: 0, exposureSettled: true)
    #expect(miss.fireReady == false)
    let hit = s.update(measurement(score: 0.72, at: 4.0), now: 4.0, placementError: 0, exposureSettled: true)
    #expect(hit.fireReady)
    #expect(hit.reason == .patience)
}

@Test func patienceNeedsFloor() {
    var s = scorer(samplePlan(subject: .none, moment: [.deviceStill(maxRadPerSec: 0.1)]))
    var fired = false
    for i in 0...80 {
        let t = Double(i) * 0.1
        fired = fired || s.update(measurement(score: 0.5, at: t), now: t, placementError: 0, exposureSettled: true).fireReady
    }
    #expect(fired == false)
}

@Test func unsettledExposureHalves() {
    var s = scorer(samplePlan(subject: .none, moment: []))
    let report = s.update(sampleMeasurement(at: 0), now: 0, placementError: 0, exposureSettled: false)
    #expect(report.score == 0.5)
}

@Test func restartResetsPatience() {
    var s = scorer(samplePlan(subject: .none, moment: [.deviceStill(maxRadPerSec: 0.1)]))
    _ = s.update(measurement(score: 0.7, at: 3.9), now: 3.9, placementError: 0, exposureSettled: true)
    s.restart(at: 4.0)
    #expect(s.update(measurement(score: 0.7, at: 4.1), now: 4.1, placementError: 0, exposureSettled: true).fireReady == false)
    #expect(s.update(measurement(score: 0.7, at: 8.0), now: 8.0, placementError: 0, exposureSettled: true).fireReady)
}

@Test func subjectPlacedNeedsSubject() {
    var s = scorer(samplePlan(subject: .none, moment: [.subjectPlaced(maxError: 0.05)]))
    let report = s.update(sampleMeasurement(), now: 0, placementError: 0.3, exposureSettled: true)
    #expect(report.statuses[0].available == false)
}
