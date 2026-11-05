extension AgentDecision {
    private enum CodingKeys: String, CodingKey {
        case action
        case settings
        case reason
        case readyToCapture
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            action: try values.decode(AgentAction.self, forKey: .action),
            settings: try values.decodeIfPresent(CameraSettings.self, forKey: .settings),
            reason: try values.decode(String.self, forKey: .reason),
            // 兼容旧响应：没有明确确认就不能触发自动拍摄。
            readyToCapture: try values.decodeIfPresent(Bool.self, forKey: .readyToCapture) ?? false
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(action, forKey: .action)
        try values.encodeIfPresent(settings, forKey: .settings)
        try values.encode(reason, forKey: .reason)
        try values.encode(readyToCapture, forKey: .readyToCapture)
    }
}
