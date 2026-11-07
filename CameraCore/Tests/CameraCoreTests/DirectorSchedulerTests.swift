import Foundation
import Testing
@testable import CameraCore

private let ready = MomentReport(statuses: [], score: 1, fireReady: true, reason: .perfect)
private let waiting = MomentReport(statuses: [], score: 0.4, fireReady: false, reason: nil)

private func makeScheduler() -> DirectorScheduler {
    DirectorScheduler(defaultPlan: { genre in samplePlan(genre: genre) })
}

private func scene(_ t: Double, change: Double = 0, subject: Bool = true) -> SceneMeasurement {
    var m = sampleMeasurement(at: t, subjects: subject ? [face()] : [], primary: subject ? 1 : nil)
    m.sceneChange = change
    return m
}

private func scout(_ genre: GenreID = .portrait, valid: Bool = false, changed: Bool = false) -> ScoutResult {
    ScoutResult(genre: genre, confidence: 0.9, sceneChanged: changed, planStillValid: valid, subjectHint: .face, reason: "r")
}

private func directorPlan() -> ShotPlan {
    var plan = samplePlan()
    plan.rationale = "导演方案"
    return plan
}

/// start(0) → scout(portrait) at 1 → director plan at 2 → composing.
private func composing() -> (DirectorScheduler, lastID: Int) {
    var s = makeScheduler()
    let start = s.handle(.start, now: 0)
    let planning = s.handle(.scoutReply(id: start.requestID!, scout()), now: 1)
    _ = s.handle(.directorReply(id: planning.requestID!, .plan(directorPlan(), nil)), now: 2)
    return (s, planning.requestID!)
}

@Test func startScouts() {
    var s = makeScheduler()
    let out = s.handle(.start, now: 0)
    #expect(out.command == .callScout)
    #expect(out.requestID == 1)
    #expect(s.phase == .scouting)
    #expect(s.plan?.genre == .general)
    #expect(s.isDefaultPlan)
}

@Test func scoutNeedsPlanAppliesGenreDefault() {
    var s = makeScheduler()
    let start = s.handle(.start, now: 0)
    let out = s.handle(.scoutReply(id: start.requestID!, scout(.portrait)), now: 1)
    #expect(s.phase == .planning)
    #expect(s.plan?.genre == .portrait)
    #expect(s.isDefaultPlan)
    #expect(out.command == .callDirector(.portrait, feedback: nil))
    #expect(out.restartMoment)
}

@Test func scoutKeepsPlanResetsBaselineNoStorm() {
    var (s, _) = composing()
    // 心跳：15 秒没有请求 → 侦察。
    let beat = s.handle(.measurement(scene(17), waiting), now: 17)
    #expect(beat.command == .callScout)
    let keep = s.handle(.scoutReply(id: beat.requestID!, scout(.portrait, valid: true)), now: 18)
    #expect(keep.resetBaseline)
    #expect(s.phase == .composing)
    #expect(s.isDefaultPlan == false)
    var t = 18.1
    while t < 31.9 {
        #expect(s.handle(.measurement(scene(t, change: 0.1), waiting), now: t).command == .none)
        t += 0.1
    }
    // 下一次心跳：上次请求（17 秒）之后 15 秒。
    #expect(s.handle(.measurement(scene(32.1, change: 0.1), waiting), now: 32.1).command == .callScout)
}

@Test func offlineFallbackAfter3s() {
    var s = makeScheduler()
    let start = s.handle(.start, now: 0)
    _ = s.handle(.requestFailed(id: start.requestID!, retryable: true, stale: false), now: 0.5)
    _ = s.handle(.measurement(scene(2.9), waiting), now: 2.9)
    #expect(s.phase == .scouting)
    let out = s.handle(.measurement(scene(3.0), waiting), now: 3.0)
    #expect(s.phase == .composing)
    #expect(s.isOffline)
    #expect(out.restartMoment)
    #expect(s.handle(.measurement(scene(3.1), ready), now: 3.1).command == .fire)
}

@Test func directorInvalidRetriesOnceThenHolds() {
    var s = makeScheduler()
    let start = s.handle(.start, now: 0)
    let first = s.handle(.scoutReply(id: start.requestID!, scout()), now: 1)
    _ = s.handle(.directorReply(id: first.requestID!, .invalid("超出范围：moment[0]")), now: 2)
    let retry = s.handle(.measurement(scene(5), waiting), now: 5)
    #expect(retry.command == .callDirector(.portrait, feedback: "超出范围：moment[0]"))
    _ = s.handle(.directorReply(id: retry.requestID!, .invalid("又错了")), now: 6)
    #expect(s.phase == .composing)
    #expect(s.isDefaultPlan)
    for t in stride(from: 6.1, through: 15.5, by: 0.1) {
        #expect(s.handle(.measurement(scene(t), waiting), now: t).command == .none)
    }
    // 心跳侦察：同一题材、场景未变 → 保持默认，不再请求导演。
    let beat = s.handle(.measurement(scene(21), waiting), now: 21)
    #expect(beat.command == .callScout)
    let keep = s.handle(.scoutReply(id: beat.requestID!, scout(.portrait)), now: 22)
    #expect(keep.command == .none)
    #expect(s.phase == .composing)
}

@Test func fireOnlyWhenReadyInPlanningOrComposing() {
    var s = makeScheduler()
    let start = s.handle(.start, now: 0)
    #expect(s.handle(.measurement(scene(0.5), ready), now: 0.5).command == .none)
    _ = s.handle(.scoutReply(id: start.requestID!, scout()), now: 1)
    #expect(s.phase == .planning)
    #expect(s.handle(.measurement(scene(1.2), ready), now: 1.2).command == .fire)
    #expect(s.phase == .capturing)
    #expect(s.handle(.measurement(scene(1.3), ready), now: 1.3).command == .none)
}

@Test func capturedGoesToCooldownAndRescoutsOnSceneChange() {
    var (s, _) = composing()
    _ = s.handle(.measurement(scene(3), ready), now: 3)
    let captured = s.handle(.captured, now: 3.5)
    #expect(s.phase == .cooldown)
    #expect(captured.resetBaseline)
    #expect(s.handle(.measurement(scene(4), ready), now: 4).command == .none)
    _ = s.handle(.measurement(scene(5, change: 0.3), waiting), now: 5)
    let moved = s.handle(.measurement(scene(5.5, change: 0.3), waiting), now: 5.5)
    #expect(s.phase == .scouting)
    #expect(moved.command == .callScout)
}

@Test func manualCaptureAlsoCoolsDown() {
    var (s, _) = composing()
    _ = s.handle(.captured, now: 3)
    #expect(s.phase == .cooldown)
}

@Test func requestIDsMonotonicAcrossRestart() {
    var s = makeScheduler()
    let first = s.handle(.start, now: 0)
    _ = s.handle(.stop, now: 1)
    let second = s.handle(.start, now: 2)
    #expect(second.requestID! > first.requestID!)
    let stale = s.handle(.scoutReply(id: first.requestID!, scout(.landscape)), now: 3)
    #expect(stale == SchedulerOutput())
    #expect(s.plan?.genre == .general)
    #expect(s.phase == .scouting)
}

@Test func staleFailureDoesNotEscalateBackoff() {
    var (s, _) = composing()
    let beat = s.handle(.measurement(scene(17), waiting), now: 17)
    _ = s.handle(.requestFailed(id: beat.requestID!, retryable: true, stale: true), now: 18)
    // 画面变化导致的丢弃：2 秒间隔后即可再侦察，没有 5 秒退避。
    _ = s.handle(.measurement(scene(19.1, change: 0.3), waiting), now: 19.1)
    #expect(s.handle(.measurement(scene(19.6, change: 0.3), waiting), now: 19.6).command == .callScout)
}

@Test func failureBacksOff() {
    var (s, _) = composing()
    let beat = s.handle(.measurement(scene(17), waiting), now: 17)
    _ = s.handle(.requestFailed(id: beat.requestID!, retryable: true, stale: false), now: 18)
    _ = s.handle(.measurement(scene(19.5, change: 0.3), waiting), now: 19.5)
    #expect(s.handle(.measurement(scene(20.5, change: 0.3), waiting), now: 20.5).command == .none)
    #expect(s.handle(.measurement(scene(23.1, change: 0.3), waiting), now: 23.1).command == .callScout)
}

@Test func nonRetryableFailureStops() {
    var s = makeScheduler()
    let start = s.handle(.start, now: 0)
    _ = s.handle(.requestFailed(id: start.requestID!, retryable: false, stale: false), now: 1)
    #expect(s.phase == .off)
}

@Test func pauseResume() {
    var (s, _) = composing()
    _ = s.handle(.pause, now: 3)
    #expect(s.phase == .paused)
    #expect(s.handle(.measurement(scene(4), ready), now: 4).command == .none)
    let resumed = s.handle(.resume, now: 5)
    #expect(s.phase == .composing)
    #expect(resumed.resetBaseline)
    #expect(resumed.restartMoment)
}

@Test func pauseDropsInFlightReply() {
    var s = makeScheduler()
    let start = s.handle(.start, now: 0)
    _ = s.handle(.pause, now: 0.5)
    _ = s.handle(.resume, now: 1)
    #expect(s.handle(.scoutReply(id: start.requestID!, scout()), now: 1.5) == SchedulerOutput())
    #expect(s.phase == .scouting)
}

@Test func fireRejectedReturnsToComposing() {
    var (s, _) = composing()
    _ = s.handle(.measurement(scene(3), ready), now: 3)
    _ = s.handle(.fireRejected, now: 3.1)
    #expect(s.phase == .composing)
}

@Test func rearmFromCooldown() {
    var (s, _) = composing()
    _ = s.handle(.captured, now: 3)
    let out = s.handle(.rearm, now: 4)
    #expect(s.phase == .composing)
    #expect(out.restartMoment)
}

@Test func subjectLostTriggersScout() {
    var (s, _) = composing()
    _ = s.handle(.measurement(scene(3, subject: false), waiting), now: 3)
    #expect(s.handle(.measurement(scene(3.5, subject: false), waiting), now: 3.5).command == .none)
    #expect(s.handle(.measurement(scene(4.0, subject: false), waiting), now: 4.0).command == .callScout)
}

@Test func genreChangeReplacesPlan() {
    var (s, _) = composing()
    let beat = s.handle(.measurement(scene(17), waiting), now: 17)
    let out = s.handle(.scoutReply(id: beat.requestID!, scout(.landscape, valid: false, changed: true)), now: 18)
    #expect(s.plan?.genre == .landscape)
    #expect(s.isDefaultPlan)
    #expect(s.phase == .planning)
    #expect(out.command == .callDirector(.landscape, feedback: nil))
    #expect(out.resetMemory)
}

/// 显著区域主体缺失不触发侦察（否则没有显著区域的场景会每 2 秒侦察一次）。
@Test func salientPlanDoesNotRescoutWhenSubjectMissing() {
    var s = DirectorScheduler(defaultPlan: { genre in samplePlan(genre: genre, subject: .salient) })
    let start = s.handle(.start, now: 0)
    let planning = s.handle(.scoutReply(id: start.requestID!, scout(.general)), now: 1)
    var salient = samplePlan(genre: .general, subject: .salient)
    salient.rationale = "通用"
    _ = s.handle(.directorReply(id: planning.requestID!, .plan(salient, nil)), now: 2)
    for t in stride(from: 3.0, through: 10.0, by: 0.1) {
        #expect(s.handle(.measurement(scene(t, subject: false), waiting), now: t).command == .none)
    }
}
