/// 七项通用评分维度，每项 0–4 分。
public enum RubricCriterion: String, Codable, CaseIterable, Sendable, CodingKeyRepresentable {
    case clarity, exposure, composition, light, background, moment, genre
}

public struct RubricScore: Codable, Equatable, Sendable {
    public var criterion: RubricCriterion
    public var score: Int
    /// 证据：引用测量值或画面中的具体位置。
    public var evidence: String

    public init(criterion: RubricCriterion, score: Int, evidence: String) {
        self.criterion = criterion
        self.score = score
        self.evidence = evidence
    }
}

public enum Verdict: String, Codable, Sendable {
    case approve, wait, revise
}

public struct RubricResult: Codable, Equatable, Sendable {
    public var scores: [RubricScore]
    public var modelVerdict: Verdict

    public init(scores: [RubricScore], modelVerdict: Verdict) {
        self.scores = scores
        self.modelVerdict = modelVerdict
    }

    public func score(_ criterion: RubricCriterion) -> Int? {
        scores.first { $0.criterion == criterion }?.score
    }

    public func weighted(_ weights: [RubricCriterion: Double]) -> Double {
        RubricCriterion.allCases.reduce(0) { $0 + (weights[$1] ?? 0) * Double(score($1) ?? 0) }
    }

    /// 放行规则：权重 > 0 的每一项都必须存在且 > 1 分，加权总分 ≥ 3.0。
    /// 模型的结论只能让结果更严，不能更宽。
    public func verdict(weights: [RubricCriterion: Double]) -> Verdict {
        if modelVerdict == .revise { return .revise }
        let gated = RubricCriterion.allCases.filter { (weights[$0] ?? 0) > 0 }
        guard gated.allSatisfy({ (score($0) ?? -1) > 1 }), weighted(weights) >= 3.0 - 1e-9 else { return .wait }
        return modelVerdict
    }
}

/// 某一维度 0 / 2 / 4 分的文字锚定。
public struct RubricAnchor: Codable, Equatable, Sendable {
    public var name: String
    public var low: String
    public var mid: String
    public var high: String
}
