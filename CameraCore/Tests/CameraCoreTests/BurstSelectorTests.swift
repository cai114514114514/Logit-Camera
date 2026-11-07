import Testing
@testable import CameraCore

@Test func portraitPrefersOpenEyes() {
    let frames = [FrameQuality(sharpness: 0.9, eyesOpen: 0.1, faceQuality: 0.5, aesthetics: 0.2),
                  FrameQuality(sharpness: 0.8, eyesOpen: 0.9, faceQuality: 0.6, aesthetics: 0.2)]
    #expect(BurstSelector.best(frames, genre: .portrait) == 1)
}

@Test func landscapePrefersSharp() {
    let frames = [FrameQuality(sharpness: 0.4, aesthetics: 0.3),
                  FrameQuality(sharpness: 0.9, aesthetics: 0.3),
                  FrameQuality(sharpness: 0.6, aesthetics: 0.35)]
    #expect(BurstSelector.best(frames, genre: .landscape) == 1)
}

@Test func missingMetricsIgnored() {
    let frames = [FrameQuality(sharpness: 0.5), FrameQuality(sharpness: 0.7, aesthetics: nil)]
    #expect(BurstSelector.best(frames, genre: .still) == 1)
    #expect(BurstSelector.scores(frames, genre: .still).map { ($0 * 1000).rounded() / 1000 } == [0, 1])
}

@Test func allMissingPicksFirst() {
    #expect(BurstSelector.best([FrameQuality(), FrameQuality(), FrameQuality()], genre: .general) == 0)
}

@Test func constantMetricIsNeutral() {
    let frames = [FrameQuality(sharpness: 0.5, aesthetics: 0.2), FrameQuality(sharpness: 0.5, aesthetics: 0.4)]
    #expect(BurstSelector.best(frames, genre: .general) == 1)
}

@Test func tinyDifferencesAreNotAmplified() {
    // 美学 0.30 对 0.35 的差异不应压过清晰度 0.6 对 0.9。
    let frames = [FrameQuality(sharpness: 0.9, aesthetics: 0.30), FrameQuality(sharpness: 0.6, aesthetics: 0.35)]
    #expect(BurstSelector.best(frames, genre: .general) == 0)
}

@Test func emptyReturnsZero() {
    #expect(BurstSelector.best([], genre: .general) == 0)
    #expect(BurstSelector.scores([], genre: .general).isEmpty)
}
