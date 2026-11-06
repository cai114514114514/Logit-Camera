/// 题材。每个题材在知识库中有一份打法（Playbook）。
public enum GenreID: String, Codable, CaseIterable, Sendable {
    case portrait, group, street, landscape, architecture, food, still, night, animal, document, general
}
