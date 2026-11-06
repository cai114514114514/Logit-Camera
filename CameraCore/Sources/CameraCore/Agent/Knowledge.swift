import Foundation

public struct GenreCues: Codable, Sendable, Equatable {
    /// 系统场景标签中的关键词（英文，与 ClassifyImageRequest 标签匹配）。
    public var labels: [String]
    public var subjects: [SubjectKind]
    /// 可测量特征的文字描述，供模型参考。
    public var measurements: [String]
}

public struct GenrePrinciples: Codable, Sendable, Equatable {
    public var composition: [String]
    public var light: [String]
    public var exposure: [String]
    public var timing: [String]
    public var faults: [String]
}

/// 一个题材的「打法」：识别线索、原则、量表权重、题材特有项与默认方案。
public struct GenrePlaybook: Codable, Sendable, Equatable {
    public var id: GenreID
    public var name: String
    public var cues: GenreCues
    public var principles: GenrePrinciples
    public var rubricWeights: [RubricCriterion: Double]
    public var genreCriterion: RubricAnchor
    public var defaultPlan: ShotPlan
    public var spaqCategories: [String]
}

public enum PromptName: String, Sendable, CaseIterable {
    case system, scout, judge
}

public enum KnowledgeError: Error, Equatable {
    case missing(String)
}

/// 随包分发的摄影知识：`Resources/Knowledge`。社区可直接修改这些 JSON / Markdown。
public enum Knowledge {
    private struct RubricFile: Codable { var anchors: [RubricCriterion: RubricAnchor] }

    private static let root: URL? = Bundle.module.url(forResource: "Knowledge", withExtension: nil)

    private static let playbooks: Result<[GenreID: GenrePlaybook], Error> = Result {
        var result: [GenreID: GenrePlaybook] = [:]
        for id in GenreID.allCases {
            let data = try Data(contentsOf: try file("genres/\(id.rawValue).json"))
            result[id] = try JSONDecoder().decode(GenrePlaybook.self, from: data)
        }
        return result
    }

    public static func playbook(_ id: GenreID) throws -> GenrePlaybook {
        guard let playbook = try playbooks.get()[id] else { throw KnowledgeError.missing(id.rawValue) }
        return playbook
    }

    public static func allPlaybooks() throws -> [GenrePlaybook] {
        let all = try playbooks.get()
        return GenreID.allCases.compactMap { all[$0] }
    }

    public static func rubricAnchors() throws -> [RubricCriterion: RubricAnchor] {
        try JSONDecoder().decode(RubricFile.self, from: Data(contentsOf: try file("rubric.json"))).anchors
    }

    public static func prompt(_ name: PromptName) throws -> String {
        try String(contentsOf: try file("prompts/\(name.rawValue).md"), encoding: .utf8)
    }

    private static func file(_ path: String) throws -> URL {
        guard let url = root?.appendingPathComponent(path), FileManager.default.fileExists(atPath: url.path) else {
            throw KnowledgeError.missing(path)
        }
        return url
    }
}
