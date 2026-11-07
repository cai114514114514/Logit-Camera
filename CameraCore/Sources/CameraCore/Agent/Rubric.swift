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

/// 旧版评审的结论（只用于解码旧的拍摄记录）。
public enum Verdict: String, Codable, Sendable {
    case approve, wait, revise
}

/// 导演对当前画面的量表点评：分数与证据。只用于让模型基于证据思考、在界面和日志中展示，不参与任何判定。
public struct RubricResult: Codable, Equatable, Sendable {
    public var scores: [RubricScore]
    public var modelVerdict: Verdict?

    public init(scores: [RubricScore], modelVerdict: Verdict? = nil) {
        self.scores = scores
        self.modelVerdict = modelVerdict
    }

    public func score(_ criterion: RubricCriterion) -> Int? {
        scores.first { $0.criterion == criterion }?.score
    }

    public func weighted(_ weights: [RubricCriterion: Double]) -> Double {
        RubricCriterion.allCases.reduce(0) { $0 + (weights[$1] ?? 0) * Double(score($1) ?? 0) }
    }
}

/// 某一维度 0 / 2 / 4 分的文字锚定。
public struct RubricAnchor: Codable, Equatable, Sendable {
    public var name: String
    public var low: String
    public var mid: String
    public var high: String
}
