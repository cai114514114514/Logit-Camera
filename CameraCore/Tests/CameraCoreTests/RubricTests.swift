import Testing
@testable import CameraCore

private let evenWeights = Dictionary(uniqueKeysWithValues: RubricCriterion.allCases.map { ($0, 1.0 / 7) })

private func result(_ score: Int, omit: RubricCriterion? = nil) -> RubricResult {
    RubricResult(scores: RubricCriterion.allCases.filter { $0 != omit }.map {
        RubricScore(criterion: $0, score: score, evidence: "证据")
    })
}

@Test func weightedScore() {
    #expect(abs(result(3).weighted(evenWeights) - 3) < 1e-9)
}

@Test func missingCriterionCountsZero() {
    #expect(abs(result(4, omit: .moment).weighted(evenWeights) - 24.0 / 7) < 1e-9)
}

@Test func critiqueHasNoVerdictByDefault() {
    #expect(result(2).modelVerdict == nil)
}
