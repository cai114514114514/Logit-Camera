/// 一次 Agent 调整前后、已格式化的硬件读数。
public struct ParameterDelta: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let before: String
    public let after: String

    public init(id: String, title: String, before: String, after: String) {
        self.id = id
        self.title = title
        self.before = before
        self.after = after
    }

    /// 只保留读数确实变化的参数，界面不展示未变化的项目。
    public static func changed(_ items: [ParameterDelta]) -> [ParameterDelta] {
        items.filter { $0.before != $0.after }
    }
}
