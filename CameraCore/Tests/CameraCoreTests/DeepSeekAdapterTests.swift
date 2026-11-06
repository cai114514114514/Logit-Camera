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

private func rubricArgs(_ score: Double = 3, verdict: String = "approve") -> JSONValue {
    var object: [String: JSONValue] = [:]
    for criterion in RubricCriterion.allCases {
        object[criterion.rawValue] = .object(["score": .number(score), "evidence": .string("clipHigh=0.004")])
    }
    object["verdict"] = .string(verdict)
    return .object(object)
}

private func planArgs(aperture: Double = 0, minCrop: Double = 0.25) -> JSONValue {
    .object([
        "genre": .string("portrait"), "genreConfidence": .number(0.9), "subject": .string("face"),
        "composition": .object([
            "ratio": .string("3:4"), "anchor": .object(["x": .number(0.33), "y": .number(0.36)]),
            "subjectSize": .object(["min": .number(0.15), "max": .number(0.25)]),
            "minCropArea": .number(minCrop), "levelHorizon": .bool(false)
        ]),
        "exposure": .object([
            "meter": .string("subject"), "subjectEV": .number(0.5), "highlightClipMax": .number(0.01),
            "aperture": .object(["mode": .string(aperture == 0 ? "auto" : "prefer"), "value": .number(aperture)]),
            "shutterFloor": .number(0.008), "isoCeiling": .number(0)
        ]),
        "triggers": .array([
            .object(["kind": .string("eyesOpen"), "threshold": .number(0.6)]),
            .object(["kind": .string("exposureSettled"), "threshold": .number(0)])
        ]),
        "holdMs": .number(200), "rationale": .string("脸朝左，主体放右侧")
    ])
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

@Test func judgeRequestEnablesThinkingAndOriginalDetail() async throws {
    let transport = StubTransport([(200, completion([("set_plan", .object(["plan": planArgs(), "rubric": rubricArgs()]))]))])
    _ = try await adapter(transport).judge(frame, playbook: try portrait(), plan: nil, memory: nil, feedback: "")
    let body = try transport.body(0)
    #expect(body["thinking"]?["type"] == .string("enabled"))
    #expect(body["reasoning_effort"] == .string("high"))
    #expect(body.allImageDetails == ["original"])
}

@Test func toolsAreStrictWithNoAdditionalProperties() throws {
    for tool in ToolSchemas.scoutTools + ToolSchemas.judgeTools {
        #expect(tool["function"]?["strict"] == .bool(true))
        try SchemaLint.checkStrict(tool["function"]?["parameters"] ?? .null)
    }
}

@Test func schemasAvoidUnsupportedKeywords() throws {
    for tool in ToolSchemas.scoutTools + ToolSchemas.judgeTools {
        let keys = tool.allKeys
        for forbidden in ["minLength", "maxLength", "minItems", "maxItems"] {
            #expect(!keys.contains(forbidden))
        }
        #expect(!tool.containsTypeNull)
    }
}

@Test func imageOnlyInUserMessage() async throws {
    let transport = StubTransport([(200, completion([("classify_scene", scoutArgs)]))])
    _ = try await adapter(transport).scout(frame, plan: nil)
    for message in try transport.body(0)["messages"]?.arrayValue ?? [] where message.allImageDetails.count > 0 {
        #expect(message["role"] == .string("user"))
    }
}

@Test func judgeMemoryEchoesReasoningContent() async throws {
    let transport = StubTransport([
        (200, completion([("set_plan", .object(["plan": planArgs(), "rubric": rubricArgs(2, verdict: "wait")]))], reasoning: "思考A")),
        (200, completion([("keep_plan", .object(["rubric": rubricArgs(), "reason": .string("好")]))], reasoning: "思考B"))
    ])
    let model = adapter(transport)
    let first = try await model.judge(frame, playbook: try portrait(), plan: nil, memory: nil, feedback: "")
    _ = try await model.judge(frame, playbook: try portrait(), plan: nil, memory: first.memory, feedback: "眼睛已睁开")
    let messages = try transport.body(1)["messages"]?.arrayValue ?? []
    let assistant = messages.first { $0["role"] == .string("assistant") }
    #expect(assistant?["reasoning_content"] == .string("思考A"))
    let tool = messages.first { $0["role"] == .string("tool") }
    #expect(tool?["tool_call_id"] == .string("call_0"))
    #expect(tool?["content"]?.stringValue?.contains("眼睛已睁开") == true)
    #expect(messages.filter { $0.allImageDetails.count > 0 }.count == 1)
}

@Test func parsesSetPlan() async throws {
    let transport = StubTransport([(200, completion([("set_plan", .object(["plan": planArgs(aperture: 2.0), "rubric": rubricArgs()]))]))])
    let outcome = try await adapter(transport).judge(frame, playbook: try portrait(), plan: nil, memory: nil, feedback: "")
    guard case .setPlan(let plan, let rubric) = outcome.result else { Issue.record("expected set_plan"); return }
    #expect(plan.composition.anchor == NormalizedPoint(x: 0.33, y: 0.36))
    #expect(plan.exposure.aperture == ApertureIntent(mode: .prefer, value: 2.0))
    #expect(plan.exposure.shutterFloor == 0.008)
    #expect(plan.exposure.isoCeiling == nil)
    #expect(plan.triggers == [.eyesOpen(min: 0.6), .exposureSettled])
    #expect(rubric.scores.count == 7)
    #expect(rubric.modelVerdict == .approve)
}

@Test func parsesKeepPlan() async throws {
    let transport = StubTransport([(200, completion([("keep_plan", .object(["rubric": rubricArgs(4, verdict: "wait"), "reason": .string("等转头")]))]))])
    let outcome = try await adapter(transport).judge(frame, playbook: try portrait(), plan: samplePlan(), memory: nil, feedback: "")
    #expect(outcome.result == .keepPlan(RubricResult(scores: RubricCriterion.allCases.map {
        RubricScore(criterion: $0, score: 4, evidence: "clipHigh=0.004") }, modelVerdict: .wait), reason: "等转头"))
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
    let badPlan = completion([("set_plan", .object(["plan": planArgs(aperture: 9), "rubric": rubricArgs()]))])
    await #expect(throws: ModelError.invalidPlan("unsupportedAperture")) {
        try await adapter(StubTransport([(200, badPlan)])).judge(frame, playbook: try portrait(), plan: nil, memory: nil, feedback: "")
    }
    let wrongTool = completion([("keep_plan", .object(["rubric": rubricArgs(), "reason": .string("")]))])
    await #expect(throws: ModelError.unexpectedTool("keep_plan")) {
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
