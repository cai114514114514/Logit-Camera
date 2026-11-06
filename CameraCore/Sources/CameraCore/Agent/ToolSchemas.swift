/// DeepSeek 严格工具定义（Beta）。不使用 null、minLength/maxLength、minItems/maxItems。
public enum ToolSchemas {
    public static let classifySceneName = "classify_scene"
    public static let setPlanName = "set_plan"
    public static let keepPlanName = "keep_plan"

    public static var scoutTools: [JSONValue] {
        [tool(classifySceneName, "识别当前画面的题材，并判断现有拍摄方案是否仍然适用。", classifyScene)]
    }

    public static var judgeTools: [JSONValue] {
        [tool(setPlanName, "给出新的完整拍摄方案，并按七项量表为当前画面打分。", setPlan),
         tool(keepPlanName, "方案不变，按七项量表为当前画面打分，并决定放行或等待。", keepPlan)]
    }

    static func parameters(of name: String) -> JSONValue? {
        switch name {
        case classifySceneName: classifyScene
        case setPlanName: setPlan
        case keepPlanName: keepPlan
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

    static var setPlan: JSONValue { object(["plan": plan, "rubric": rubric]) }

    static var keepPlan: JSONValue { object(["rubric": rubric, "reason": string("放行或等待的理由；等待时说明在等什么")]) }

    static var plan: JSONValue {
        object([
            "genre": enumeration(GenreID.allCases.map(\.rawValue)),
            "genreConfidence": number(0, 1),
            "subject": enumeration(SubjectKind.allCases.map(\.rawValue)),
            "composition": object([
                "ratio": enumeration(FrameRatio.allCases.map(\.rawValue)),
                "anchor": object(["x": number(0, 1), "y": number(0, 1)], "主体中心在裁切框中的位置，原点左上"),
                "subjectSize": object(["min": number(0.05, 1), "max": number(0.05, 1)], "主体高度占裁切框高度的范围"),
                "minCropArea": number(0.25, 1, "裁切面积下限，相对传感器面积"),
                "levelHorizon": .object(["type": "boolean"])
            ]),
            "exposure": object([
                "meter": enumeration([MeterMode.subject, .highlights, .scene].map(\.rawValue)),
                "subjectEV": number(-2, 2, "主体相对中灰的目标亮度"),
                "highlightClipMax": number(0, 0.05),
                "aperture": object(["mode": enumeration(["auto", "prefer"]),
                                    "value": number(0, 32, "prefer 时填 f 值，auto 时填 0")]),
                "shutterFloor": number(0, 30, "最慢快门秒数；0 表示不限制"),
                "isoCeiling": number(0, 100_000, "ISO 上限；0 表示不限制")
            ]),
            "triggers": .object([
                "type": "array",
                "items": object(["kind": enumeration(Trigger.Kind.allCases.map(\.rawValue)),
                                 "threshold": number(0, 45, "exposureSettled 与 subjectPresent 填 0")])
            ]),
            "holdMs": .object(["type": "integer", "minimum": 0, "maximum": 1000]),
            "rationale": string("中文，不超过 60 字")
        ])
    }

    static var rubric: JSONValue {
        var properties: [String: JSONValue] = [:]
        for criterion in RubricCriterion.allCases {
            properties[criterion.rawValue] = object([
                "score": .object(["type": "integer", "minimum": 0, "maximum": 4]),
                "evidence": string("引用测量值或画面中的具体位置")
            ])
        }
        properties["verdict"] = enumeration([Verdict.approve, .wait, .revise].map(\.rawValue))
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

    private static func enumeration(_ values: [String]) -> JSONValue {
        ["type": "string", "enum": .array(values.map { .string($0) })]
    }
}
