import Foundation

/// 把知识库、方案与测量拼成提示词。纯函数，便于测试与离线评测复用。
public enum PromptBuilder {
    public static func scoutSystem(plan: ShotPlan?) throws -> String {
        let genres = try Knowledge.allPlaybooks().map { playbook in
            let cues = playbook.cues
            let labels = cues.labels.isEmpty ? "—" : cues.labels.joined(separator: "/")
            return "- \(playbook.id.rawValue)（\(playbook.name)）：标签 \(labels)；主体 \(cues.subjects.map(\.rawValue).joined(separator: "/"))；\(cues.measurements.joined(separator: "；"))"
        }.joined(separator: "\n")
        let scout = try Knowledge.prompt(.scout)
            .replacingOccurrences(of: "{{GENRES}}", with: genres)
            .replacingOccurrences(of: "{{PLAN}}", with: planText(plan))
        return try Knowledge.prompt(.system) + "\n\n" + scout
    }

    public static func directorSystem(playbook: GenrePlaybook, plan: ShotPlan?, feedback: String) throws -> String {
        let anchors = try Knowledge.rubricAnchors()
        var rubricLines = RubricCriterion.allCases.compactMap { criterion -> String? in
            guard let anchor = anchors[criterion] else { return nil }
            return "- \(criterion.rawValue)（\(anchor.name)）：0 = \(anchor.low)；2 = \(anchor.mid)；4 = \(anchor.high)"
        }
        let g = playbook.genreCriterion
        rubricLines.append("- genre（\(g.name)）：0 = \(g.low)；2 = \(g.mid)；4 = \(g.high)")
        let weights = RubricCriterion.allCases
            .map { "\($0.rawValue) \(String(format: "%.2f", playbook.rubricWeights[$0] ?? 0))" }
            .joined(separator: "，")
        let director = try Knowledge.prompt(.director)
            .replacingOccurrences(of: "{{GENRE_NAME}}", with: playbook.name)
            .replacingOccurrences(of: "{{PLAYBOOK}}", with: playbookText(playbook))
            .replacingOccurrences(of: "{{RUBRIC}}", with: rubricLines.joined(separator: "\n"))
            .replacingOccurrences(of: "{{WEIGHTS}}", with: weights)
            .replacingOccurrences(of: "{{PLAN}}", with: planText(plan))
            .replacingOccurrences(of: "{{FEEDBACK}}", with: feedback.isEmpty ? "无" : feedback)
        return try Knowledge.prompt(.system) + "\n\n" + director
    }

    static func playbookText(_ playbook: GenrePlaybook) -> String {
        let p = playbook.principles
        func section(_ title: String, _ items: [String]) -> String {
            "### \(title)\n" + items.map { "- \($0)" }.joined(separator: "\n")
        }
        let defaultPlan = (try? JSONValue.from(playbook.defaultPlan).compactString()) ?? "{}"
        return [section("构图", p.composition), section("光线", p.light), section("曝光", p.exposure),
                section("时机", p.timing), section("常见失误", p.faults),
                "### 默认方案（起点）\n" + defaultPlan].joined(separator: "\n\n")
    }

    static func planText(_ plan: ShotPlan?) -> String {
        guard let plan, let json = try? JSONValue.from(plan) else { return "无" }
        return json.compactString()
    }

    /// 发给模型的测量摘要：数值保留 3 位有效数字，直方图压缩为 16 档。
    public static func measurementText(_ frame: ModelFrame) -> String {
        let m = frame.measurement
        let h = m.luminance.histogram
        let histogram16: [JSONValue] = stride(from: 0, to: h.count, by: 4).map {
            .number(round3(h[$0..<min($0 + 4, h.count)].reduce(0, +)))
        }
        let subjects: [JSONValue] = m.subjects.map { s in
            var o: [String: JSONValue] = [
                "id": .number(Double(s.id)), "kind": .string(s.kind.rawValue),
                "box": [.number(round3(s.box.x)), .number(round3(s.box.y)), .number(round3(s.box.width)), .number(round3(s.box.height))],
                "confidence": .number(round3(s.confidence))
            ]
            if let yaw = s.yaw { o["yawDeg"] = .number(round3(yaw)) }
            if let eyes = s.eyeOpenness { o["eyeOpenness"] = .number(round3(eyes)) }
            if let quality = s.faceQuality { o["faceQuality"] = .number(round3(quality)) }
            return .object(o)
        }
        var measurement: [String: JSONValue] = [
            "subjects": .array(subjects),
            "primarySubjectID": m.primarySubjectID.map { .number(Double($0)) } ?? .null,
            "luminance": ["mean": .number(round3(m.luminance.mean)),
                          "subjectMean": m.luminance.subjectMean.map { .number(round3($0)) } ?? .null,
                          "clipHigh": .number(round3(m.luminance.clipHigh)), "clipLow": .number(round3(m.luminance.clipLow)),
                          "histogram16": .array(histogram16)],
            "sharpness": ["global": .number(round3(m.sharpness.global)),
                          "subject": m.sharpness.subject.map { .number(round3($0)) } ?? .null],
            "horizonDeg": m.horizonDegrees.map { .number(round3($0)) } ?? .null,
            "deviceAngularSpeed": .number(round3(m.deviceAngularSpeed)),
            "subjectSpeed": .number(round3(m.subjectSpeed)),
            "sceneChange": .number(round3(m.sceneChange))
        ]
        if let a = m.aesthetics {
            measurement["systemAesthetics"] = ["score": .number(round3(a.score)), "isUtility": .bool(a.isUtility),
                                               "labels": .array(a.labels.map { .string($0) })]
        }
        let l = frame.limits
        let limits: JSONValue = [
            "aperture": [.number(round3(l.minAperture)), .number(round3(l.maxAperture))],
            "apertureStops": .array(l.apertureStops.map { .number(round3($0)) }),
            "iso": [.number(l.minISO), .number(l.maxISO)],
            "shutterSeconds": [.number(l.minShutter), .number(l.maxShutter)],
            "lensStopsMM": .array(l.lensStops.map { .number(round3($0)) })
        ]
        return "本地测量：" + JSONValue.object(measurement).compactString() + "\n设备能力：" + limits.compactString()
    }

    static func round3(_ value: Double) -> Double {
        guard value.isFinite, value != 0 else { return 0 }
        let digits = 3 - Int(floor(log10(abs(value)))) - 1
        let scale = pow(10, Double(max(0, digits)))
        return (value * scale).rounded() / scale
    }
}
