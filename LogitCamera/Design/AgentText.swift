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
        }
    }

    /// 还没达到的时机信号（数据缺失的不算）。
    static func waiting(_ report: MomentReport?) -> String? {
        guard let report else { return nil }
        let missing = report.statuses.filter { $0.available && !$0.satisfied }.map { trigger($0.trigger.kind) }
        return missing.isEmpty ? nil : "还在等：" + missing.joined(separator: "、")
    }

    static func meter(_ mode: MeterMode) -> String {
        switch mode {
        case .subject: "以主体测光"
        case .highlights: "保护高光"
        case .scene: "整体测光"
        }
    }

    static func motion(_ motion: MotionIntent) -> String {
        switch motion {
        case .freeze: "冻结动作"
        case .normal: "手持安全"
        case .blur: "允许拖影"
        }
    }

    static func depth(_ depth: DepthIntent) -> String {
        switch depth {
        case .shallow: "浅景深"
        case .normal: "常规景深"
        case .deep: "大景深"
        }
    }

    static func lens(_ plan: ShotPlan, current: LensStop?) -> String {
        if let current { return "\(Int(current.focalLength)) mm · " + CameraText.zoom(Float(current.zoomFactor)) }
        return plan.lens.focalLength > 0 ? "\(Int(plan.lens.focalLength)) mm" : "题材默认焦段"
    }

    static func exposure(_ e: ExposureIntent) -> String {
        var parts = [meter(e.meter), motion(e.motion), depth(e.depth), String(format: "主体 %+.1f EV", e.subjectEV)]
        if e.shutterFloor > 0 { parts.append("快门 ≥ " + CameraText.shutter(e.shutterFloor)) }
        if e.isoCeiling > 0 { parts.append("ISO ≤ \(Int(e.isoCeiling))") }
        return parts.joined(separator: " · ")
    }

    static func composition(_ c: Composition) -> String {
        String(format: "%@ · 主体在 (%.2f, %.2f) · 占比 %.0f–%.0f%%", c.ratio.rawValue, c.anchor.x, c.anchor.y,
               c.subjectSize.min * 100, c.subjectSize.max * 100) + (c.levelHorizon ? " · 地平线水平" : "")
    }
}
