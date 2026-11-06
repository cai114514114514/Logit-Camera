import Foundation
import Testing
@testable import CameraCore

private let even = Dictionary(uniqueKeysWithValues: RubricCriterion.allCases.map { ($0, 1.0 / 7) })
private let ready = TriggerReport(statuses: [], allSatisfied: true, sustained: true, nearlyReady: true)
private let close = TriggerReport(statuses: [], allSatisfied: false, sustained: false, nearlyReady: true)
private let far = TriggerReport(statuses: [], allSatisfied: false, sustained: false, nearlyReady: false)

private func makeScheduler() -> DirectorScheduler {
    DirectorScheduler(weights: { _ in even }, defaultPlan: { genre in
        var plan = samplePlan()
        plan.genre = genre
        return plan
    })
}

private func rubric(_ score: Int, _ verdict: Verdict = .approve) -> RubricResult {
    RubricResult(scores: RubricCriterion.allCases.map { RubricScore(criterion: $0, score: score, evidence: "e") },
                 modelVerdict: verdict)
}

private func scene(_ t: Double, change: Double = 0, subject: Bool = true) -> SceneMeasurement {
    var m = sampleMeasurement(at: t, subjects: subject ? [face()] : [], primary: subject ? 1 : nil)
    m.sceneChange = change
    return m
}

private func scout(_ genre: GenreID = .portrait, valid: Bool = false, changed: Bool = false) -> ScoutResult {
    ScoutResult(genre: genre, confidence: 0.9, sceneChanged: changed, planStillValid: valid, subjectHint: .face, reason: "r")
}

/// start(0) → scout reply(1) → judge set_plan(wait) at 2 → tracking.
private func tracking() -> DirectorScheduler {
    var s = makeScheduler()
    _ = s.handle(.start, now: 0)
    _ = s.handle(.scoutReply(generation: s.generation, scout()), now: 1)
    _ = s.handle(.judgeReply(generation: s.generation, .setPlan(samplePlan(), rubric(2, .wait))), now: 2)
    return s
}

private func armed() -> DirectorScheduler {
    var s = tracking()
    _ = s.handle(.measurement(scene(10), close), now: 10)
    _ = s.handle(.measurement(scene(10.6), close), now: 10.6)
    _ = s.handle(.judgeReply(generation: s.generation, .keepPlan(rubric(4), reason: "好")), now: 11)
    return s
}

@Test func startCallsScout() {
    var s = makeScheduler()
    #expect(s.handle(.start, now: 0).command == .callScout)
    #expect(s.phase == .scouting)
    #expect(s.inFlight)
}

@Test func startAppliesGeneralDefaultPlanWithoutArming() {
    var s = makeScheduler()
    _ = s.handle(.start, now: 0)
    #expect(s.plan?.genre == .general)
    #expect(s.isDefaultPlan)
    #expect(s.handle(.measurement(scene(0.1), ready), now: 0.1).command != .fire)
}

@Test func newGenreRequestsPlan() {
    var s = makeScheduler()
    _ = s.handle(.start, now: 0)
    let out = s.handle(.scoutReply(generation: s.generation, scout(.portrait)), now: 1)
    #expect(out.command == .callJudge(.plan(.portrait)))
    #expect(out.resetMemory)
    #expect(s.phase == .planning)
}

@Test func newPlanResetsJudgeMemory() {
    var s = tracking()
    let heartbeat = s.handle(.measurement(scene(20), far), now: 20)
    #expect(heartbeat.command == .callScout)
    let same = s.handle(.scoutReply(generation: s.generation, scout(.portrait, valid: true)), now: 21)
    #expect(same.resetMemory == false)
    #expect(s.phase == .tracking)
}

@Test func setPlanEntersTracking() {
    let s = tracking()
    #expect(s.phase == .tracking)
    #expect(s.plan?.genre == .portrait)
    #expect(s.isDefaultPlan == false)
}

@Test func nearlyReadyRequestsApproval() {
    var s = tracking()
    #expect(s.handle(.measurement(scene(10), close), now: 10).command == .none)
    #expect(s.handle(.measurement(scene(10.6), close), now: 10.6).command == .callJudge(.approve))
    #expect(s.phase == .reviewing)
}

@Test func approveArmsOnlyWhenRubricPasses() {
    var s = tracking()
    _ = s.handle(.measurement(scene(10), close), now: 10)
    _ = s.handle(.measurement(scene(10.6), close), now: 10.6)
    _ = s.handle(.judgeReply(generation: s.generation, .keepPlan(rubric(2), reason: "")), now: 11)
    #expect(s.phase == .tracking)
    #expect(armed().phase == .armed)
}

@Test func armedFiresWhenSustained() {
    var s = armed()
    #expect(s.handle(.measurement(scene(11.1), ready), now: 11.1).command == .fire)
    #expect(s.phase == .capturing)
}

@Test func approvalExpiresAfterTenSeconds() {
    var s = armed()
    _ = s.handle(.measurement(scene(21.1), far), now: 21.1)
    #expect(s.phase == .tracking)
}

@Test func driftDisarms() {
    var s = armed()
    _ = s.handle(.measurement(scene(12, change: 0.1), ready), now: 12)
    #expect(s.phase == .tracking)
}

@Test func sceneChangeTriggersScoutAfterHalfSecond() {
    var s = tracking()
    #expect(s.handle(.measurement(scene(10, change: 0.3), far), now: 10).command == .none)
    #expect(s.handle(.measurement(scene(10.6, change: 0.3), far), now: 10.6).command == .callScout)
}

@Test func scoutRespectsTwoSecondSpacing() {
    var s = makeScheduler()
    _ = s.handle(.start, now: 0)
    _ = s.handle(.scoutReply(generation: s.generation, scout()), now: 0.3)
    _ = s.handle(.judgeReply(generation: s.generation, .setPlan(samplePlan(), rubric(2, .wait))), now: 0.8)
    _ = s.handle(.measurement(scene(1.0, change: 0.3), far), now: 1.0)
    #expect(s.handle(.measurement(scene(1.6, change: 0.3), far), now: 1.6).command == .none)
    #expect(s.handle(.measurement(scene(2.1, change: 0.3), far), now: 2.1).command == .callScout)
}

@Test func judgeRespectsFourSecondSpacing() {
    var s = tracking()
    _ = s.handle(.measurement(scene(2.0), close), now: 2.0)
    #expect(s.handle(.measurement(scene(2.6), close), now: 2.6).command == .none)
    #expect(s.handle(.measurement(scene(5.1), close), now: 5.1).command == .callJudge(.approve))
}

@Test func heartbeatAfterFifteenSeconds() {
    var s = tracking()
    #expect(s.handle(.measurement(scene(15.9), far), now: 15.9).command == .none)
    #expect(s.handle(.measurement(scene(16.1), far), now: 16.1).command == .callScout)
}

@Test func subjectLostTriggersScout() {
    var s = tracking()
    _ = s.handle(.measurement(scene(10, subject: false), far), now: 10)
    #expect(s.handle(.measurement(scene(10.5, subject: false), far), now: 10.5).command == .none)
    #expect(s.handle(.measurement(scene(11.1, subject: false), far), now: 11.1).command == .callScout)
}

@Test func onlyOneRequestInFlight() {
    var s = makeScheduler()
    _ = s.handle(.start, now: 0)
    for t in stride(from: 0.5, through: 20, by: 0.5) {
        #expect(s.handle(.measurement(scene(t, change: 0.5), close), now: t).command == .none)
    }
}

@Test func responseAfterStopIsIgnored() {
    var s = makeScheduler()
    _ = s.handle(.start, now: 0)
    let generation = s.generation
    _ = s.handle(.stop, now: 0.5)
    #expect(s.handle(.scoutReply(generation: generation, scout()), now: 1).command == .none)
    #expect(s.phase == .off)
    #expect(s.plan == nil)
}

@Test func staleGenerationIsIgnored() {
    var s = makeScheduler()
    _ = s.handle(.start, now: 0)
    let old = s.generation
    _ = s.handle(.pause, now: 0.1)
    _ = s.handle(.resume, now: 0.2)
    _ = s.handle(.scoutReply(generation: old, scout()), now: 1)
    #expect(s.phase == .scouting)
    #expect(s.isDefaultPlan)
}

@Test func pauseKeepsPlanButStopsFiring() {
    var s = armed()
    _ = s.handle(.pause, now: 11.05)
    #expect(s.handle(.measurement(scene(11.1), ready), now: 11.1).command == .none)
    #expect(s.phase == .paused)
    #expect(s.plan != nil)
}

@Test func cooldownRearmsOnSceneChange() {
    var s = armed()
    _ = s.handle(.measurement(scene(11.1), ready), now: 11.1)
    _ = s.handle(.captured, now: 11.5)
    #expect(s.phase == .cooldown)
    #expect(s.handle(.measurement(scene(12, change: 0.3), far), now: 12).command == .none)
    #expect(s.handle(.measurement(scene(12.6, change: 0.3), far), now: 12.6).command == .callScout)
    #expect(s.phase == .scouting)
}

@Test func rearmReturnsToTracking() {
    var s = armed()
    _ = s.handle(.measurement(scene(11.1), ready), now: 11.1)
    _ = s.handle(.captured, now: 11.5)
    _ = s.handle(.rearm, now: 12)
    #expect(s.phase == .tracking)
}

@Test func failuresBackOff() {
    var s = makeScheduler()
    _ = s.handle(.start, now: 0)
    _ = s.handle(.requestFailed(generation: s.generation, retryable: true), now: 1)
    #expect(s.handle(.measurement(scene(5.9), far), now: 5.9).command == .none)
    #expect(s.handle(.measurement(scene(6.1), far), now: 6.1).command == .callScout)
    _ = s.handle(.requestFailed(generation: s.generation, retryable: true), now: 6.2)
    #expect(s.handle(.measurement(scene(16.1), far), now: 16.1).command == .none)
    #expect(s.handle(.measurement(scene(16.3), far), now: 16.3).command == .callScout)
}

@Test func nonRetryableFailureStops() {
    var s = makeScheduler()
    _ = s.handle(.start, now: 0)
    _ = s.handle(.requestFailed(generation: s.generation, retryable: false), now: 1)
    #expect(s.phase == .off)
}

@Test func reviseRequestsNewPlan() {
    var s = tracking()
    _ = s.handle(.measurement(scene(10), close), now: 10)
    _ = s.handle(.measurement(scene(10.6), close), now: 10.6)
    _ = s.handle(.judgeReply(generation: s.generation, .keepPlan(rubric(3, .revise), reason: "")), now: 11)
    #expect(s.phase == .planning)
    #expect(s.handle(.measurement(scene(14.7), far), now: 14.7).command == .callJudge(.plan(.portrait)))
}
