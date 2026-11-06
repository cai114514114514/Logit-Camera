import Foundation

/// 发给模型的一帧：取景图、本地测量与设备能力。
public struct ModelFrame: Sendable {
    public let jpeg: Data
    public let measurement: SceneMeasurement
    public let limits: CameraLimits
    public let timestamp: TimeInterval

    public init(jpeg: Data, measurement: SceneMeasurement, limits: CameraLimits, timestamp: TimeInterval) {
        self.jpeg = jpeg
        self.measurement = measurement
        self.limits = limits
        self.timestamp = timestamp
    }
}

/// 评审档的对话记忆：上一轮的用户文字（不含图像）、助手回复（含思考内容）与工具调用 id。
/// 思考模式 + 工具调用要求回传 reasoning_content。
public struct JudgeMemory: Sendable, Equatable {
    public let previousUser: JSONValue
    public let assistant: JSONValue
    public let toolCallID: String
}

public struct TokenUsage: Sendable, Equatable {
    public let prompt: Int
    public let completion: Int
}

public struct JudgeOutcome: Sendable, Equatable {
    public let result: JudgeResult
    public let memory: JudgeMemory
    public let usage: TokenUsage?
}

public enum ModelError: Error, Equatable, Sendable {
    case authentication
    case rateLimited
    case http(Int)
    case truncated
    case noToolCall
    case multipleToolCalls
    case unexpectedTool(String)
    case schema(String)
    case invalidPlan(String)
    case transport(String)

    /// 密钥与额度问题不重试，其余错误退避后重试。
    public var isRetryable: Bool { self != .authentication }
}

/// 视觉模型服务商接口。本期只有 DeepSeek 实现。
public protocol VisionModel: Sendable {
    func scout(_ frame: ModelFrame, plan: ShotPlan?) async throws -> ScoutResult
    func judge(_ frame: ModelFrame, playbook: GenrePlaybook, plan: ShotPlan?,
               memory: JudgeMemory?, feedback: String) async throws -> JudgeOutcome
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// 默认传输：临时会话、不缓存、拒绝重定向（密钥只发往配置的端点）。
public final class URLSessionTransport: NSObject, HTTPTransport, URLSessionTaskDelegate, Sendable {
    private let session: URLSession

    public override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 40
        session = URLSession(configuration: configuration)
        super.init()
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request, delegate: self)
        guard let http = response as? HTTPURLResponse else { throw ModelError.transport("非 HTTP 响应") }
        return (data, http)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? { nil }
}
