/// 参数当前由谁决定：系统自动、用户手动或 AI。界面据此着色。
public enum ValueOrigin: Sendable {
    case automatic, user, ai

    public static func of(isManual: Bool, agentOwned: Bool) -> ValueOrigin {
        guard isManual else { return .automatic }
        return agentOwned ? .ai : .user
    }
}
