import CameraCore
import Foundation

struct ExposureReading: Codable, Sendable {
    let aperture: Double
    let iso: Double
    let shutterSeconds: Double
    let zoom: Double
    let exposureBias: Double
    let apertureAuto: Bool
    let isoAuto: Bool
    let shutterAuto: Bool
    let adjustingExposure: Bool
    let adjustingFocus: Bool
}

struct ObservationContext: Codable, Sendable {
    let settings: CameraSettings
    let actual: ExposureReading
    let limits: CameraLimits
}

struct CameraObservation: Sendable {
    let frame: CameraFrame
    let context: ObservationContext
}

struct AgentToolCall: Codable, Sendable {
    let id: String
    let type: String
    let function: Function
    struct Function: Codable, Sendable { let name: String; let arguments: String }
}

struct AgentExchange: Sendable {
    let call: AgentToolCall
    let outcome: String
}

struct AgentReply: Sendable {
    let decision: AgentDecision
    let call: AgentToolCall
    let model: String
}

final class DeepSeekClient: Sendable {
    private let session: URLSession
    private let redirects = RejectRedirects()

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: redirects, delegateQueue: nil)
    }

    func decide(observation: CameraObservation, previous: AgentExchange?, key: String) async throws -> AgentReply {
        var messages: [[String: Any]] = [["role": "system", "content": CameraPrompt.system]]
        if let previous {
            let call = try JSONSerialization.jsonObject(with: JSONEncoder().encode(previous.call))
            messages.append(["role": "user", "content": "继续上一轮相机控制；下面是你的上次工具调用及设备执行结果。"])
            messages.append(["role": "assistant", "content": NSNull(), "tool_calls": [call]])
            messages.append(["role": "tool", "tool_call_id": previous.call.id, "content": previous.outcome])
        }
        let context = String(decoding: try JSONEncoder().encode(observation.context), as: UTF8.self)
        messages.append(["role": "user", "content": [
            ["type": "text", "text": "当前设备观测 JSON：\n" + context],
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + observation.frame.jpeg.base64EncodedString(), "detail": "low"]]
        ]])
        let body: [String: Any] = [
            "model": AICredentials.model, "messages": messages,
            "tools": CameraPrompt.tools, "tool_choice": "required",
            "parallel_tool_calls": false, "thinking": ["type": "disabled"],
            "max_tokens": 500, "temperature": 0.2, "stream": false
        ]
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        switch http.statusCode {
        case 200: break
        case 401, 402, 403: throw AIError.authentication
        case 429: throw AIError.rateLimited
        default: throw AIError.message("DeepSeek 暂时不可用（HTTP \(http.statusCode)），当前参数未更改。")
        }
        let result = try JSONDecoder().decode(Completion.self, from: data)
        guard let choice = result.choices.first, choice.finish_reason == "tool_calls",
              let calls = choice.message.tool_calls, calls.count == 1,
              let call = calls.first, call.type == "function", !call.id.isEmpty,
              let arguments = call.function.arguments.data(using: .utf8) else { throw AIError.invalidResponse }
        let decision: AgentDecision
        switch call.function.name {
        case "adjust_camera":
            let input = try JSONDecoder().decode(Adjustment.self, from: arguments)
            decision = AgentDecision(action: .adjust, settings: input.settings, reason: input.reason)
        case "hold_camera":
            let input = try JSONDecoder().decode(Hold.self, from: arguments)
            decision = AgentDecision(action: .hold, settings: nil, reason: input.reason, readyToCapture: input.readyToCapture)
        default: throw AIError.invalidResponse
        }
        try decision.validate(against: observation.context.limits)
        return AgentReply(decision: decision, call: call, model: result.model)
    }

    private struct Completion: Decodable {
        let model: String
        let choices: [Choice]
        struct Choice: Decodable {
            let finish_reason: String
            let message: Message
            struct Message: Decodable { let tool_calls: [AgentToolCall]? }
        }
    }
    private struct Adjustment: Decodable { let settings: CameraSettings; let reason: String }
    private struct Hold: Decodable { let reason: String; let readyToCapture: Bool }

    private final class RejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
