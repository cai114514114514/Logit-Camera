import CameraCore
import Foundation

/// Logit Camera 离线工具（说明见 eval/README.md）。
///   probe <image>   用真实 API 依次调用 scout、direct（新方案）、direct（带记忆），打印结果与延迟。
///   bench           快档测量算法的耗时（请用 -c release）。
///   sample / run    生成评测清单 / 运行离线评测。
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
    let first = try await model.direct(frame, playbook: playbook, plan: nil, memory: nil, feedback: "")
    print("[direct \(elapsed(start))] usage=\(String(describing: first.usage))")
    describe(first.plan)
    report(first.critique, playbook)

    start = ContinuousClock.now
    let second = try await model.direct(frame, playbook: playbook, plan: first.plan, memory: first.memory,
                                        feedback: "方案已执行；画面未变化，手机静止。")
    print("[direct+memory \(elapsed(start))] usage=\(String(describing: second.usage))")
    describe(second.plan)
    report(second.critique, playbook)
}

func describe(_ p: ShotPlan) {
    print("  set_plan: \(p.genre.rawValue) \(Int(p.lens.focalLength))mm \(p.composition.ratio.rawValue) anchor=(\(p.composition.anchor.x), \(p.composition.anchor.y)) — \(p.rationale)")
    print("  exposure: meter=\(p.exposure.meter.rawValue) ev=\(p.exposure.subjectEV) motion=\(p.exposure.motion.rawValue) depth=\(p.exposure.depth.rawValue)")
    print("  moment: \(p.moment.map { "\($0.kind.rawValue) \($0.threshold)" }.joined(separator: ", "))")
}

func report(_ rubric: RubricResult, _ playbook: GenrePlaybook) {
    for score in rubric.scores { print("    \(score.criterion.rawValue)=\(score.score)  \(score.evidence)") }
    print(String(format: "    加权 %.2f", rubric.weighted(playbook.rubricWeights)))
}

/// 快档纯计算的耗时（320×240 灰度图）：亮度统计、两次清晰度、签名与场景变化。
func bench() {
    let width = 240, height = 320
    var seed: UInt64 = 42
    let bytes = (0..<(width * height)).map { _ -> UInt8 in
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return UInt8(truncatingIfNeeded: seed >> 56)
    }
    let image = LumaImage(width: width, height: height, bytes: bytes)
    let subject = NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.7)
    let baseline = MeasurementMath.signature(image)
    let rounds = 200
    let start = ContinuousClock.now
    var sink = 0.0
    for _ in 0..<rounds {
        let stats = MeasurementMath.luminance(image, subject: subject)
        sink += stats.mean + MeasurementMath.sharpness(image, region: nil) + MeasurementMath.sharpness(image, region: subject)
        sink += MeasurementMath.sceneChange(baseline, MeasurementMath.signature(image))
    }
    let elapsed = ContinuousClock.now - start
    let ms = (Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15) / Double(rounds)
    print(String(format: "快档计算 %.3f ms/帧（%d 轮，校验 %.1f）", ms, rounds, sink))
}

do {
    switch arguments.first {
    case "bench": bench()
    case "sample": try sample(Options(arguments.dropFirst()))
    case "run": try await run(Options(arguments.dropFirst()))
    case "probe" where arguments.count == 2: try await probe(arguments[1])
    default:
        print("""
    用法：
      LogitEval probe <image>
      LogitEval bench
      LogitEval sample --labels <labels.csv> --out <manifest.json> [--per-category 20] [--dataset spaq]
      LogitEval run --manifest <manifest.json> --images <dir> [--limit N] [--out results.json]
    """)
        exit(2)
    }
} catch {
    print("失败：\(error)")
    exit(1)
}
