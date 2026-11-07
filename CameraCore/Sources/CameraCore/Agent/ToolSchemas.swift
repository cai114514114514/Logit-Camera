/// DeepSeek 严格工具定义（Beta）。不使用 null、minLength/maxLength、minItems/maxItems。
public enum ToolSchemas {
    public static let classifySceneName = "classify_scene"
    public static let setPlanName = "set_plan"

    public static var scoutTools: [JSONValue] {
        [tool(classifySceneName, "识别当前画面的题材，并判断现有拍摄方案是否仍然适用。", classifyScene)]
    }

    /// 导演只有一个工具：给出完整意图并点评当前画面。描述里写明本机可用的镜头档。
    public static func directorTools(limits: CameraLimits?) -> [JSONValue] {
        [tool(setPlanName, "给出完整的拍摄意图（焦段、构图、曝光意图、时机信号），并按七项量表点评当前画面。",
              setPlan(limits: limits))]
    }

    static func parameters(of name: String) -> JSONValue? {
        switch name {
        case classifySceneName: classifyScene
        case setPlanName: setPlan(limits: nil)
        default: nil
        }
    }

    // MARK: - Schemas

    static var classifyScene: JSONValue {
        object([
            "genre": enumeration(GenreID.allCases.map(\.rawValue)),
            "confidence": number(0, 1),
            "sceneChanged": .object(["type": "boolean"]),
            "planStillValid": .object(["type": "boolean"]),
            "subjectHint": enumeration(SubjectKind.allCases.map(\.rawValue)),
            "reason": string("一句中文判断依据")
        ])
    }

    static func setPlan(limits: CameraLimits?) -> JSONValue {
        object(["plan": plan(limits: limits), "critique": critique])
    }

    /// 例如「13/24/48/96」。
    static func lensStopsText(_ limits: CameraLimits?) -> String {
        guard let stops = limits?.lensStops, !stops.isEmpty else { return "24/48" }
        return stops.map { String(Int($0.rounded())) }.joined(separator: "/")
    }

    static var momentRangesText: String {
        Trigger.Kind.allCases.map(\.rangeText).joined(separator: "；")
    }

    static func plan(limits: CameraLimits?) -> JSONValue {
        object([
            "genre": enumeration(GenreID.allCases.map(\.rawValue)),
            "genreConfidence": number(0, 1),
            "subject": enumeration(SubjectKind.allCases.map(\.rawValue)),
            "composition": object([
                "ratio": enumeration(FrameRatio.allCases.map(\.rawValue)),
                "anchor": object(["x": number(0, 1), "y": number(0, 1)], "主体中心在裁切框中的位置，原点左上"),
                "subjectSize": object(["min": number(0.05, 1), "max": number(0.05, 1)], "主体高度占裁切框高度的范围"),
                "minCropArea": number(0.25, 1, "裁切面积下限，相对全画幅面积"),
                "levelHorizon": .object(["type": "boolean"])
            ]),
            "lens": object([
                "focalLength": number(0, 300, "等效焦距 mm，可用镜头档 \(lensStopsText(limits))；0 表示题材默认")
            ]),
            "exposure": object([
                "meter": enumeration([MeterMode.subject, .highlights, .scene].map(\.rawValue)),
                "subjectEV": number(-2, 2, "主体相对 18% 中灰的目标亮度（EV）"),
                "highlightClipMax": number(0, 0.05),
                "motion": enumeration(MotionIntent.allCases.map(\.rawValue), "freeze 冻结动作；normal 手持安全；blur 允许拖影"),
                "depth": enumeration(DepthIntent.allCases.map(\.rawValue), "shallow 浅景深；normal；deep 前后都清楚"),
                "shutterFloor": number(0, 1, "最慢快门秒数；0 表示由程序决定，否则 0.001–1"),
                "isoCeiling": number(0, 12800, "ISO 上限；0 表示由程序决定，否则 100–12800")
            ]),
            "moment": .object([
                "type": "array",
                "description": "时机信号（加分项，不是前提）",
                "items": object(["kind": enumeration(Trigger.Kind.allCases.map(\.rawValue)),
                                 "threshold": number(0, 45, "各信号的取值范围：\(momentRangesText)")])
            ]),
            "holdMs": .object(["type": "integer", "minimum": 0, "maximum": 1000]),
            "rationale": string("中文，不超过 60 字")
        ])
    }

    static var critique: JSONValue {
        var properties: [String: JSONValue] = [:]
        for criterion in RubricCriterion.allCases {
            properties[criterion.rawValue] = object([
                "score": .object(["type": "integer", "minimum": 0, "maximum": 4]),
                "evidence": string("引用测量值或画面中的具体位置")
            ])
        }
        return object(properties)
    }

    // MARK: - Builders

    private static func tool(_ name: String, _ description: String, _ parameters: JSONValue) -> JSONValue {
        ["type": "function",
         "function": ["name": .string(name), "description": .string(description), "strict": true, "parameters": parameters]]
    }

    private static func object(_ properties: [String: JSONValue], _ description: String? = nil) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": "object", "properties": .object(properties),
            "required": .array(properties.keys.sorted().map { .string($0) }), "additionalProperties": false
        ]
        if let description { schema["description"] = .string(description) }
        return .object(schema)
    }

    private static func number(_ minimum: Double, _ maximum: Double, _ description: String? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "number", "minimum": .number(minimum), "maximum": .number(maximum)]
        if let description { schema["description"] = .string(description) }
        return .object(schema)
    }

    private static func string(_ description: String) -> JSONValue {
        ["type": "string", "description": .string(description)]
    }

    private static func enumeration(_ values: [String], _ description: String? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "string", "enum": .array(values.map { .string($0) })]
        if let description { schema["description"] = .string(description) }
        return .object(schema)
    }
}
