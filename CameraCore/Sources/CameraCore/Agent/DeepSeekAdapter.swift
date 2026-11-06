import Foundation

/// DeepSeek 适配器：两档都用 deepseek-flash。
/// scout：关闭思考、低清图；judge：开启思考（high）、原图、回传上一轮 reasoning_content。
public struct DeepSeekAdapter: VisionModel {
    public static let model = "deepseek-flash"
    public static let betaEndpoint = URL(string: "https://api.deepseek.com/beta/chat/completions")!

    private let key: String
    private let transport: HTTPTransport
    private let endpoint: URL

    public init(key: String, transport: HTTPTransport = URLSessionTransport(), endpoint: URL = DeepSeekAdapter.betaEndpoint) {
        self.key = key
        self.transport = transport
        self.endpoint = endpoint
    }

    public func scout(_ frame: ModelFrame, plan: ShotPlan?) async throws -> ScoutResult {
        let messages: [JSONValue] = [
            ["role": "system", "content": .string(try PromptBuilder.scoutSystem(plan: plan))],
            userMessage(frame, detail: "low")
        ]
        let reply = try await send(messages: messages, tools: ToolSchemas.scoutTools, thinking: false, timeout: 10,
                                   allowed: [ToolSchemas.classifySceneName])
        do { return try reply.arguments.decode(ScoutResult.self) }
        catch { throw ModelError.schema("classify_scene 无法解析") }
    }

    public func judge(_ frame: ModelFrame, playbook: GenrePlaybook, plan: ShotPlan?,
                      memory: JudgeMemory?, feedback: String) async throws -> JudgeOutcome {
        var messages: [JSONValue] = [
            ["role": "system", "content": .string(try PromptBuilder.judgeSystem(playbook: playbook, plan: plan, feedback: feedback))]
        ]
        if let memory {
            messages += [memory.previousUser, memory.assistant,
                         ["role": "tool", "tool_call_id": .string(memory.toolCallID),
                          "content": .string("本地执行反馈：" + (feedback.isEmpty ? "无变化" : feedback))]]
        }
        let current = userMessage(frame, detail: "original")
        messages.append(current)
        let reply = try await send(messages: messages, tools: ToolSchemas.judgeTools, thinking: true, timeout: 30,
                                   allowed: [ToolSchemas.setPlanName, ToolSchemas.keepPlanName])
        let rubric = try Self.rubric(from: reply.arguments["rubric"])
        let result: JudgeResult
        if reply.name == ToolSchemas.setPlanName {
            let newPlan = try Self.plan(from: reply.arguments["plan"])
            do { try newPlan.validate(against: frame.limits) }
            catch let error as PlanValidationError { throw ModelError.invalidPlan(Self.describe(error)) }
            result = .setPlan(newPlan, rubric)
        } else {
            result = .keepPlan(rubric, reason: reply.arguments["reason"]?.stringValue ?? "")
        }
        // 记忆里只保留上一轮的文字（去掉图像），避免重复发送图片。
        let textOnly: JSONValue = ["role": "user", "content": .string("上一轮画面（图像省略）\n" + PromptBuilder.measurementText(frame))]
        return JudgeOutcome(result: result, memory: JudgeMemory(previousUser: textOnly, assistant: reply.assistant,
                                                                toolCallID: reply.callID), usage: reply.usage)
    }

    // MARK: - Request

    private func userMessage(_ frame: ModelFrame, detail: String) -> JSONValue {
        ["role": "user", "content": [
            ["type": "text", "text": .string(PromptBuilder.measurementText(frame))],
            ["type": "image_url", "image_url": [
                "url": .string("data:image/jpeg;base64," + frame.jpeg.base64EncodedString()), "detail": .string(detail)]]
        ]]
    }

    private struct Reply {
        let name: String
        let arguments: JSONValue
        let assistant: JSONValue
        let callID: String
        let usage: TokenUsage?
    }

    private func send(messages: [JSONValue], tools: [JSONValue], thinking: Bool, timeout: TimeInterval,
                      allowed: [String]) async throws -> Reply {
        var body: [String: JSONValue] = [
            "model": .string(Self.model), "messages": .array(messages), "tools": .array(tools),
            // 思考模式不支持 tool_choice = required（真实 API 返回 400），只能 auto；提示词要求恰好调用一个工具。
            "tool_choice": thinking ? "auto" : "required", "stream": false,
            "thinking": ["type": thinking ? "enabled" : "disabled"],
            "max_tokens": .number(thinking ? 8000 : 600)
        ]
        if thinking { body["reasoning_effort"] = "high" } else { body["temperature"] = 0.2 }

        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))

        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await transport.send(request) }
        catch let error as ModelError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw ModelError.transport(error.localizedDescription) }

        switch response.statusCode {
        case 200: break
        case 401, 402, 403: throw ModelError.authentication
        case 429: throw ModelError.rateLimited
        default: throw ModelError.http(response.statusCode)
        }
        return try Self.parse(data, allowed: allowed)
    }

    private static func parse(_ data: Data, allowed: [String]) throws -> Reply {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              let choice = json["choices"]?.arrayValue?.first, let message = choice["message"] else {
            throw ModelError.schema("响应不是有效的 chat completion")
        }
        if choice["finish_reason"]?.stringValue == "length" { throw ModelError.truncated }
        let calls = message["tool_calls"]?.arrayValue ?? []
        guard !calls.isEmpty else { throw ModelError.noToolCall }
        guard calls.count == 1, let call = calls.first else { throw ModelError.multipleToolCalls }
        guard let name = call["function"]?["name"]?.stringValue, let callID = call["id"]?.stringValue else {
            throw ModelError.schema("工具调用缺少名称或 id")
        }
        guard allowed.contains(name), let schema = ToolSchemas.parameters(of: name) else {
            throw ModelError.unexpectedTool(name)
        }
        guard let text = call["function"]?["arguments"]?.stringValue,
              let arguments = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else {
            throw ModelError.schema("工具参数不是 JSON")
        }
        try SchemaValidator.validate(arguments, against: schema)

        var assistant: [String: JSONValue] = ["role": "assistant", "content": .null, "tool_calls": .array([call])]
        if let reasoning = message["reasoning_content"] { assistant["reasoning_content"] = reasoning }
        let usage = json["usage"].flatMap { u -> TokenUsage? in
            guard let p = u["prompt_tokens"]?.doubleValue, let c = u["completion_tokens"]?.doubleValue else { return nil }
            return TokenUsage(prompt: Int(p), completion: Int(c))
        }
        return Reply(name: name, arguments: arguments, assistant: .object(assistant), callID: callID, usage: usage)
    }

    // MARK: - Conversion

    /// 工具里「0 表示不限制 / auto 时填 0」转换回方案中的空值。
    static func plan(from arguments: JSONValue?) throws -> ShotPlan {
        guard var plan = arguments?.objectValue, var exposure = plan["exposure"]?.objectValue else {
            throw ModelError.schema("缺少 plan")
        }
        for key in ["shutterFloor", "isoCeiling"] where exposure[key]?.doubleValue == 0 {
            exposure.removeValue(forKey: key)
        }
        if exposure["aperture"]?["mode"] == "auto" { exposure["aperture"] = ["mode": "auto"] }
        plan["exposure"] = .object(exposure)
        do { return try JSONValue.object(plan).decode(ShotPlan.self) }
        catch { throw ModelError.schema("plan 无法解析") }
    }

    static func rubric(from arguments: JSONValue?) throws -> RubricResult {
        guard let arguments, let verdict = arguments["verdict"]?.stringValue.flatMap(Verdict.init(rawValue:)) else {
            throw ModelError.schema("缺少 rubric")
        }
        let scores = try RubricCriterion.allCases.map { criterion -> RubricScore in
            guard let item = arguments[criterion.rawValue], let score = item["score"]?.doubleValue,
                  let evidence = item["evidence"]?.stringValue else { throw ModelError.schema("rubric.\(criterion.rawValue) 缺失") }
            return RubricScore(criterion: criterion, score: Int(score), evidence: evidence)
        }
        return RubricResult(scores: scores, modelVerdict: verdict)
    }

    static func describe(_ error: PlanValidationError) -> String {
        switch error {
        case .outOfRange(let name): "outOfRange(\(name))"
        case .invalidRange(let name): "invalidRange(\(name))"
        case .unsupportedAperture: "unsupportedAperture"
        }
    }
}
