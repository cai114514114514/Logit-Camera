import Foundation
import Testing
@testable import CameraCore

@Test func captionPriorityPickedOverWaiting() {
    var director = CaptionDirector()
    var s = CaptionSnapshot(phase: .composing, genre: .portrait, waitingFor: .eyesOpen)
    _ = director.update(s, now: 0)
    _ = director.update(s, now: 1.6)
    s.pickedAt = 2
    #expect(director.update(s, now: 2) == "挑了眼睛睁开的一张")
}

@Test func captionTruncatesTo16() {
    var director = CaptionDirector()
    let long = String(repeating: "光", count: 30)
    let text = director.update(CaptionSnapshot(phase: .composing, isDefaultPlan: false, planID: UUID(), rationale: long), now: 0)
    #expect(text?.count == 16)
}

@Test func captionDoesNotRepeatWithin8s() {
    var director = CaptionDirector()
    #expect(director.update(CaptionSnapshot(phase: .composing, isOffline: true), now: 0) == "没有网络，先按经验拍")
    _ = director.update(CaptionSnapshot(phase: .composing, isOffline: false), now: 2)
    #expect(director.update(CaptionSnapshot(phase: .composing, isOffline: true), now: 3) == nil)
    _ = director.update(CaptionSnapshot(phase: .composing, isOffline: false), now: 8.5)
    #expect(director.update(CaptionSnapshot(phase: .composing, isOffline: true), now: 9) == "没有网络，先按经验拍")
}

@Test func waitingNeedsHold() {
    var director = CaptionDirector()
    let s = CaptionSnapshot(phase: .composing, waitingFor: .eyesOpen)
    #expect(director.update(s, now: 0) == nil)
    #expect(director.update(s, now: 1.0) == nil)
    #expect(director.update(s, now: 1.6) == "等眼睛睁开")
}

@Test func lensPhraseByIntent() {
    #expect(CaptionDirector.lensPhrase(LensStop(focalLength: 48, zoomFactor: 2, lens: .wide), depth: .shallow) == "换到 2×，背景虚一点")
    #expect(CaptionDirector.lensPhrase(LensStop(focalLength: 13, zoomFactor: 0.5, lens: .ultraWide), depth: .deep) == "换到 0.5×，装下整个空间")
    #expect(CaptionDirector.lensPhrase(LensStop(focalLength: 96, zoomFactor: 4, lens: .telephoto), depth: .normal) == "换到 4×，拉近一点")
    #expect(CaptionDirector.lensPhrase(LensStop(focalLength: 24, zoomFactor: 1, lens: .wide), depth: .normal) == "换到 1×")
}

@Test func lensChangeAnnouncedButNotInitialMain() {
    var director = CaptionDirector()
    let main = LensStop(focalLength: 24, zoomFactor: 1, lens: .wide)
    #expect(director.update(CaptionSnapshot(phase: .planning, lens: main), now: 0) == nil)
    let portrait = LensStop(focalLength: 48, zoomFactor: 2, lens: .wide)
    #expect(director.update(CaptionSnapshot(phase: .planning, lens: portrait, depth: .shallow), now: 1) == "换到 2×，背景虚一点")
}

@Test func rationaleFirstClause() {
    #expect(CaptionDirector.firstClause("24mm 竖裁收住山脊与水线，以高光为基准压住天空") == "24mm 竖裁收住山脊与水线")
    #expect(CaptionDirector.firstClause("，") == nil)
}

@Test func scoutingCaptionOnce() {
    var director = CaptionDirector()
    let s = CaptionSnapshot(phase: .scouting)
    #expect(director.update(s, now: 0) == "在看这是什么场景")
    #expect(director.update(s, now: 1) == "在看这是什么场景")
    #expect(director.update(s, now: 3) == nil)
}

@Test func genreNamedOnDefaultPlan() {
    var director = CaptionDirector()
    _ = director.update(CaptionSnapshot(phase: .scouting), now: 0)
    #expect(director.update(CaptionSnapshot(phase: .planning, genre: .portrait, genreName: "人像"), now: 3) == "像是人像")
}

@Test func offClearsCaption() {
    var director = CaptionDirector()
    _ = director.update(CaptionSnapshot(phase: .scouting), now: 0)
    #expect(director.update(CaptionSnapshot(phase: .off), now: 0.5) == nil)
}
