import CameraCore

/// 界面上使用的 AI 文案。
enum AgentText {
    static func trigger(_ kind: Trigger.Kind) -> String {
        switch kind {
        case .subjectSharp: "清晰"
        case .eyesOpen: "睁眼"
        case .faceToward: "朝向"
        case .horizonLevel: "水平"
        case .deviceStill: "稳定"
        case .subjectPlaced: "构图"
        case .highlightsSafe: "高光"
        case .exposureSettled: "曝光"
        case .subjectPresent: "主体"
        }
    }

    static func waiting(_ report: TriggerReport?) -> String? {
        guard let report else { return nil }
        let missing = report.statuses.filter { !$0.satisfied }.map { trigger($0.trigger.kind) }
        return missing.isEmpty ? nil : "等待：" + missing.joined(separator: "、")
    }

    static func meter(_ mode: MeterMode) -> String {
        switch mode {
        case .subject: "以主体测光"
        case .highlights: "以高光测光"
        case .scene: "整体测光"
        }
    }

    static func exposure(_ e: ExposureIntent) -> String {
        var parts = [meter(e.meter), String(format: "主体 %+.1f EV", e.subjectEV),
                     String(format: "高光溢出 ≤ %.1f%%", e.highlightClipMax * 100)]
        if e.aperture.mode == .prefer, let value = e.aperture.value { parts.append(CameraText.aperture(Float(value))) }
        if let floor = e.shutterFloor { parts.append("快门 ≥ " + CameraText.shutter(floor)) }
        if let ceiling = e.isoCeiling { parts.append("ISO ≤ \(Int(ceiling))") }
        return parts.joined(separator: " · ")
    }

    static func composition(_ c: Composition) -> String {
        String(format: "%@ · 主体在 (%.2f, %.2f) · 占比 %.0f–%.0f%%", c.ratio.rawValue, c.anchor.x, c.anchor.y,
               c.subjectSize.min * 100, c.subjectSize.max * 100) + (c.levelHorizon ? " · 地平线水平" : "")
    }
}
