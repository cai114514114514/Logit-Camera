import CameraCore
import Foundation

/// Logit Camera 离线工具。
///   probe <image>   用真实 API 依次调用 scout、judge（新方案）、judge（带记忆复核），打印结果与延迟。
let arguments = Array(CommandLine.arguments.dropFirst())

func elapsed(_ start: ContinuousClock.Instant) -> String {
    let d = ContinuousClock.now - start
    return String(format: "%.1fs", Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
}

func probe(_ path: String) async throws {
    let frame = evalFrame(try ImageLoading.load(URL(fileURLWithPath: path)))
    let model = DeepSeekAdapter(key: try apiKey(), transport: DiagnosticTransport())
    print("图片 \(frame.jpeg.count / 1024) KB")

    var start = ContinuousClock.now
    let scout = try await model.scout(frame, plan: nil)
    print("[scout \(elapsed(start))] \(scout.genre.rawValue) \(scout.confidence) valid=\(scout.planStillValid) — \(scout.reason)")

    let playbook = try Knowledge.playbook(scout.genre)
    start = ContinuousClock.now
    let first = try await model.judge(frame, playbook: playbook, plan: nil, memory: nil, feedback: "")
    print("[judge \(elapsed(start))] usage=\(String(describing: first.usage))")
    var plan: ShotPlan?
    switch first.result {
    case .setPlan(let p, let rubric):
        plan = p
        print("  set_plan: \(p.composition.ratio.rawValue) anchor=(\(p.composition.anchor.x), \(p.composition.anchor.y)) — \(p.rationale)")
        print("  triggers: \(p.triggers.map { "\($0.kind.rawValue)\($0.threshold.map { "≤/≥\($0)" } ?? "")" }.joined(separator: ", "))")
        report(rubric, playbook)
    case .keepPlan(let rubric, let reason):
        print("  keep_plan (无方案时不应出现): \(reason)")
        report(rubric, playbook)
    }

    start = ContinuousClock.now
    let second = try await model.judge(frame, playbook: playbook, plan: plan, memory: first.memory,
                                       feedback: "方案已应用；画面未变化，手机静止。")
    print("[judge+memory \(elapsed(start))] usage=\(String(describing: second.usage))")
    switch second.result {
    case .setPlan(_, let rubric): print("  set_plan（替换）"); report(rubric, playbook)
    case .keepPlan(let rubric, let reason): print("  keep_plan: \(reason)"); report(rubric, playbook)
    }
}

func report(_ rubric: RubricResult, _ playbook: GenrePlaybook) {
    for score in rubric.scores { print("    \(score.criterion.rawValue)=\(score.score)  \(score.evidence)") }
    print(String(format: "    加权 %.2f  模型 %@  规则结论 %@", rubric.weighted(playbook.rubricWeights),
                 rubric.modelVerdict.rawValue, rubric.verdict(weights: playbook.rubricWeights).rawValue))
}

do {
    switch arguments.first {
    case "probe" where arguments.count == 2: try await probe(arguments[1])
    default:
        print("用法：LogitEval probe <image>")
        exit(2)
    }
} catch {
    print("失败：\(error)")
    exit(1)
}
