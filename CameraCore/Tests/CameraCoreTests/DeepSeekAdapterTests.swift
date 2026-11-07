import Foundation
import Testing
@testable import CameraCore

/// 记录请求并返回固定响应的传输层，不联网。
private final class StubTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(Int, Data)]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [(Int, Data)]) { self.responses = responses }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, data) = lock.withLock {
            requests.append(request)
            return responses.removeFirst()
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func body(_ index: Int) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: requests[index].httpBody ?? Data())
    }
}

private func completion(_ calls: [(String, JSONValue)], finish: String = "tool_calls",
                        reasoning: String? = nil) -> Data {
    let toolCalls: [JSONValue] = calls.enumerated().map { index, call in
        let arguments = String(decoding: try! JSONEncoder().encode(call.1), as: UTF8.self)
        return .object(["id": .string("call_\(index)"), "type": .string("function"),
                        "function": .object(["name": .string(call.0), "arguments": .string(arguments)])])
    }
    var message: [String: JSONValue] = ["role": .string("assistant"), "content": .null]
    if !toolCalls.isEmpty { message["tool_calls"] = .array(toolCalls) }
    if let reasoning { message["reasoning_content"] = .string(reasoning) }
    let body: JSONValue = .object([
        "model": .string("deepseek-flash"),
        "choices": .array([.object(["index": .number(0), "finish_reason": .string(finish), "message": .object(message)])]),
        "usage": .object(["prompt_tokens": .number(1200), "completion_tokens": .number(300)])
    ])
    return try! JSONEncoder().encode(body)
}

private let scoutArgs: JSONValue = .object([
    "genre": .string("portrait"), "confidence": .number(0.8), "sceneChanged": .bool(false),
    "planStillValid": .bool(false), "subjectHint": .string("face"), "reason": .string("一张人脸占主导")
])

private func critiqueArgs(_ score: Double = 3) -> JSONValue {
    var object: [String: JSONValue] = [:]
    for criterion in RubricCriterion.allCases {
        object[criterion.rawValue] = .object(["score": .number(score), "evidence": .string("clipHigh=0.004")])
    }
    return .object(object)
}

private func planArgs(focal: Double = 48, faceToward: Double = 25, minCrop: Double = 0.25) -> JSONValue {
    .object([
        "genre": .string("portrait"), "genreConfidence": .number(0.9), "subject": .string("face"),
        "composition": .object([
            "ratio": .string("3:4"), "anchor": .object(["x": .number(0.33), "y": .number(0.36)]),
            "subjectSize": .object(["min": .number(0.15), "max": .number(0.25)]),
            "minCropArea": .number(minCrop), "levelHorizon": .bool(false)
        ]),
        "lens": .object(["focalLength": .number(focal)]),
        "exposure": .object([
            "meter": .string("subject"), "subjectEV": .number(0.5), "highlightClipMax": .number(0.01),
            "motion": .string("freeze"), "depth": .string("shallow"),
            "shutterFloor": .number(0), "isoCeiling": .number(0)
        ]),
        "moment": .array([
            .object(["kind": .string("eyesOpen"), "threshold": .number(0.6)]),
            .object(["kind": .string("faceToward"), "threshold": .number(faceToward)])
        ]),
        "holdMs": .number(200), "rationale": .string("脸朝左，主体放右侧")
    ])
}

private func setPlan(_ plan: JSONValue = planArgs(), critique: JSONValue = critiqueArgs()) -> (String, JSONValue) {
    ("set_plan", .object(["plan": plan, "critique": critique]))
}

private let frame = ModelFrame(jpeg: Data([0xFF, 0xD8, 0xFF]), measurement: sampleMeasurement(subjects: [face()], primary: 1),
                               limits: typicalLimits, timestamp: 0)

private func adapter(_ transport: StubTransport) -> DeepSeekAdapter {
    DeepSeekAdapter(key: "sk-test", transport: transport)
}

private func portrait() throws -> GenrePlaybook { try Knowledge.playbook(.portrait) }

@Test func scoutRequestDisablesThinkingAndUsesLowDetail() async throws {
    let transport = StubTransport([(200, completion([("classify_scene", scoutArgs)]))])
    let result = try await adapter(transport).scout(frame, plan: nil)
    #expect(result.genre == .portrait)
    let body = try transport.body(0)
    #expect(transport.requests[0].url?.absoluteString == "https://api.deepseek.com/beta/chat/completions")
    #expect(transport.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
    #expect(body["model"] == .string("deepseek-flash"))
    #expect(body["thinking"]?["type"] == .string("disabled"))
    #expect(body.allImageDetails == ["low"])
}

@Test func directorRequestEnablesThinkingAndOriginalDetail() async throws {
    let transport = StubTransport([(200, completion([setPlan()]))])
    _ = try await adapter(transport).direct(frame, playbook: try portrait(), plan: nil, memory: nil, feedback: "")
    let body = try transport.body(0)
    #expect(body["thinking"]?["type"] == .string("enabled"))
    #expect(body["reasoning_effort"] == .string("high"))
    #expect(body.allImageDetails == ["original"])
}

@Test func toolsAreStrictWithNoAdditionalProperties() throws {
    for tool in ToolSchemas.scoutTools + ToolSchemas.directorTools(limits: typicalLimits) {
        #expect(tool["function"]?["strict"] == .bool(true))
        try SchemaLint.checkStrict(tool["function"]?["parameters"] ?? .null)
    }
}

@Test func schemasAvoidUnsupportedKeywords() throws {
    for tool in ToolSchemas.scoutTools + ToolSchemas.directorTools(limits: typicalLimits) {
        let keys = tool.allKeys
        for forbidden in ["minLength", "maxLength", "minItems", "maxItems"] {
            #expect(!keys.contains(forbidden))
        }
        #expect(!tool.containsTypeNull)
    }
}

@Test func directorToolHasOnlySetPlan() {
    let tools = ToolSchemas.directorTools(limits: typicalLimits)
    #expect(tools.count == 1)
    #expect(tools[0]["function"]?["name"] == .string("set_plan"))
}

@Test func momentThresholdDescriptionsListPerKindRanges() throws {
    let plan = ToolSchemas.plan(limits: typicalLimits)
    let description = plan["properties"]?["moment"]?["items"]?["properties"]?["threshold"]?["description"]?.stringValue ?? ""
    #expect(description.contains("faceToward 0–45"))
    #expect(description.contains("highlightsSafe 0–0.05"))
    #expect(description.contains("deviceStill 0–2"))
}

@Test func focalLengthDescribesDeviceStops() {
    let plan = ToolSchemas.plan(limits: typicalLimits)
    let description = plan["properties"]?["lens"]?["properties"]?["focalLength"]?["description"]?.stringValue ?? ""
    #expect(description.contains("13/24/48/120"))
}

@Test func critiqueHasNoVerdict() {
    let critique = ToolSchemas.setPlan(limits: nil)["properties"]?["critique"]
    #expect(critique?["properties"]?["verdict"] == nil)
    #expect(critique?["properties"]?["clarity"] != nil)
}

@Test func imageOnlyInUserMessage() async throws {
    let transport = StubTransport([(200, completion([("classify_scene", scoutArgs)]))])
    _ = try await adapter(transport).scout(frame, plan: nil)
    for message in try transport.body(0)["messages"]?.arrayValue ?? [] where message.allImageDetails.count > 0 {
        #expect(message["role"] == .string("user"))
    }
}

@Test func directorMemoryEchoesReasoningContent() async throws {
    let transport = StubTransport([
        (200, completion([setPlan(critique: critiqueArgs(2))], reasoning: "思考A")),
        (200, completion([setPlan()], reasoning: "思考B"))
    ])
    let model = adapter(transport)
    let first = try await model.direct(frame, playbook: try portrait(), plan: nil, memory: nil, feedback: "")
    _ = try await model.direct(frame, playbook: try portrait(), plan: first.plan, memory: first.memory, feedback: "眼睛已睁开")
    let messages = try transport.body(1)["messages"]?.arrayValue ?? []
    let assistant = messages.first { $0["role"] == .string("assistant") }
    #expect(assistant?["reasoning_content"] == .string("思考A"))
    let tool = messages.first { $0["role"] == .string("tool") }
    #expect(tool?["tool_call_id"] == .string("call_0"))
    #expect(tool?["content"]?.stringValue?.contains("眼睛已睁开") == true)
    #expect(messages.filter { $0.allImageDetails.count > 0 }.count == 1)
}

@Test func parsesSetPlanIntoOutcome() async throws {
    let transport = StubTransport([(200, completion([setPlan()]))])
    let outcome = try await adapter(transport).direct(frame, playbook: try portrait(), plan: nil, memory: nil, feedback: "")
    #expect(outcome.plan.composition.anchor == NormalizedPoint(x: 0.33, y: 0.36))
    #expect(outcome.plan.lens.focalLength == 48)
    #expect(outcome.plan.exposure.motion == .freeze)
    #expect(outcome.plan.exposure.shutterFloor == 0)
    #expect(outcome.plan.moment == [.eyesOpen(min: 0.6), .faceToward(maxYaw: 25)])
    #expect(outcome.critique.scores.count == 7)
    #expect(outcome.critique.modelVerdict == nil)
    #expect(outcome.usage == TokenUsage(prompt: 1200, completion: 300))
}

@Test func invalidPlanThrowsWithFieldText() async throws {
    let wrong = completion([setPlan(planArgs(focal: 250))])
    await #expect {
        try await adapter(StubTransport([(200, wrong)])).direct(frame, playbook: try portrait(), plan: nil, memory: nil, feedback: "")
    } throws: { error in
        guard case .invalidPlan(let text) = error as? ModelError else { return false }
        return text.contains("lens.focalLength")
    }
}

@Test func directorPromptStatesNoGate() throws {
    let prompt = try PromptBuilder.directorSystem(playbook: try portrait(), plan: nil, feedback: "超出范围：moment[1]")
    #expect(prompt.contains("你不决定是否按快门") || prompt.contains("也不决定是否按快门"))
    #expect(prompt.contains("超出范围：moment[1]"))
    #expect(!prompt.contains("keep_plan"))
}

@Test func measurementTextIncludesLensStops() {
    let text = PromptBuilder.measurementText(frame)
    #expect(text.contains("lensStopsMM"))
    #expect(text.contains("120"))
}

@Test func malformedRepliesAreFailures() async throws {
    let cases: [(Data, ModelError)] = [
        (completion([("classify_scene", scoutArgs)], finish: "length"), .truncated),
        (completion([]), .noToolCall),
        (completion([("classify_scene", scoutArgs), ("classify_scene", scoutArgs)]), .multipleToolCalls),
    ]
    for (data, expected) in cases {
        await #expect(throws: expected) { try await adapter(StubTransport([(200, data)])).scout(frame, plan: nil) }
    }
    var extra = scoutArgs.objectValue ?? [:]
    extra["mood"] = .string("happy")
    await #expect(throws: ModelError.self) {
        try await adapter(StubTransport([(200, completion([("classify_scene", .object(extra))]))])).scout(frame, plan: nil)
    }
    let wrongTool = completion([setPlan()])
    await #expect(throws: ModelError.unexpectedTool("set_plan")) {
        try await adapter(StubTransport([(200, wrongTool)])).scout(frame, plan: nil)
    }
}

@Test func httpStatusesMapToErrors() async throws {
    for (status, expected) in [(401, ModelError.authentication), (402, .authentication), (403, .authentication),
                               (429, .rateLimited), (500, .http(500))] {
        await #expect(throws: expected) {
            try await adapter(StubTransport([(status, Data())])).scout(frame, plan: nil)
        }
    }
}

@Test func retryableClassification() {
    #expect(ModelError.authentication.isRetryable == false)
    #expect(ModelError.rateLimited.isRetryable)
    #expect(ModelError.truncated.isRetryable)
}

/// 真实 API：思考模式不支持 tool_choice = required（HTTP 400）。scout 仍强制调用工具。
@Test func directorDoesNotForceToolChoiceInThinkingMode() async throws {
    let transport = StubTransport([(200, completion([("classify_scene", scoutArgs)])),
                                   (200, completion([setPlan()]))])
    let model = adapter(transport)
    _ = try await model.scout(frame, plan: nil)
    _ = try await model.direct(frame, playbook: try portrait(), plan: nil, memory: nil, feedback: "")
    #expect(try transport.body(0)["tool_choice"] == .string("required"))
    #expect(try transport.body(1)["tool_choice"] == .string("auto"))
}
