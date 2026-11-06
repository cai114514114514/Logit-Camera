import Testing
@testable import CameraCore

private let evenWeights = Dictionary(uniqueKeysWithValues: RubricCriterion.allCases.map { ($0, 1.0 / 7) })

private func result(_ score: Int, override: [RubricCriterion: Int] = [:], model: Verdict = .approve,
                    omit: RubricCriterion? = nil) -> RubricResult {
    RubricResult(scores: RubricCriterion.allCases.filter { $0 != omit }.map {
        RubricScore(criterion: $0, score: override[$0] ?? score, evidence: "证据")
    }, modelVerdict: model)
}

@Test func verdictRequiresEveryCriterionAboveOne() {
    #expect(result(3).verdict(weights: evenWeights) == .approve)
    #expect(result(4, override: [.light: 1]).verdict(weights: evenWeights) == .wait)
}

@Test func verdictRequiresWeightedThree() {
    #expect(result(2).verdict(weights: evenWeights) == .wait)
    #expect(abs(result(3).weighted(evenWeights) - 3) < 1e-9)
}

@Test func modelCannotLoosenVerdict() {
    #expect(result(2, model: .approve).verdict(weights: evenWeights) == .wait)
    #expect(result(4, model: .wait).verdict(weights: evenWeights) == .wait)
    #expect(result(4, model: .revise).verdict(weights: evenWeights) == .revise)
}

@Test func missingCriterionIsWait() {
    #expect(result(4, omit: .moment).verdict(weights: evenWeights) == .wait)
}

@Test func zeroWeightCriteriaDoNotGate() {
    var weights = Dictionary(uniqueKeysWithValues: RubricCriterion.allCases.map { ($0, 0.0) })
    weights[.clarity] = 0.6
    weights[.exposure] = 0.4
    #expect(result(4, override: [.light: 0, .moment: 0]).verdict(weights: weights) == .approve)
}
