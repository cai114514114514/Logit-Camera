import CameraCore
import Foundation

/// 命令行参数：--key value。
struct Options {
    private let values: [String: String]

    init(_ arguments: ArraySlice<String>) {
        var values: [String: String] = [:]
        var iterator = arguments.makeIterator()
        while let key = iterator.next() {
            if key.hasPrefix("--"), let value = iterator.next() { values[String(key.dropFirst(2))] = value }
        }
        self.values = values
    }

    func required(_ key: String) throws -> String {
        guard let value = values[key] else { throw EvalError.message("缺少参数 --\(key)") }
        return value
    }

    func optional(_ key: String) -> String? { values[key] }
}

func sample(_ options: Options) throws {
    let text = try String(contentsOfFile: try options.required("labels"), encoding: .utf8)
    let rows = try EvalSampler.parseCSV(text)
    let manifest = try EvalSampler.sample(rows, perCategory: Int(options.optional("per-category") ?? "20") ?? 20,
                                          dataset: options.optional("dataset") ?? "spaq")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let out = try options.required("out")
    try encoder.encode(manifest).write(to: URL(fileURLWithPath: out))
    print("已写入 \(manifest.items.count) 项 → \(out)")
}

struct EvalRecord: Codable {
    let file: String
    let expectedGenres: [GenreID]
    let predictedGenre: GenreID?
    let humanScore: Double
    let weighted: Double?
    let verdict: String?
    let scoutSeconds: Double?
    let judgeSeconds: Double?
    let promptTokens: Int?
    let completionTokens: Int?
    let error: String?
}

func run(_ options: Options) async throws {
    let manifest = try JSONDecoder().decode(EvalManifest.self,
                                            from: Data(contentsOf: URL(fileURLWithPath: try options.required("manifest"))))
    let images = URL(fileURLWithPath: try options.required("images"))
    let limit = Int(options.optional("limit") ?? "") ?? manifest.items.count
    let model = DeepSeekAdapter(key: try apiKey(), transport: DiagnosticTransport())
    var records: [EvalRecord] = []

    for (index, item) in manifest.items.prefix(limit).enumerated() {
        var predicted: GenreID?, weighted: Double?, verdict: String?, scoutTime: Double?, judgeTime: Double?
        var usage: TokenUsage?, failure: String?
        do {
            let frame = evalFrame(try ImageLoading.load(images.appendingPathComponent(item.file)))
            var start = ContinuousClock.now
            let scout = try await model.scout(frame, plan: nil)
            scoutTime = seconds(since: start)
            predicted = scout.genre
            let playbook = try Knowledge.playbook(scout.genre)
            start = ContinuousClock.now
            let outcome = try await model.judge(frame, playbook: playbook, plan: nil, memory: nil, feedback: "")
            judgeTime = seconds(since: start)
            usage = outcome.usage
            let rubric: RubricResult = switch outcome.result {
            case .setPlan(_, let r): r
            case .keepPlan(let r, _): r
            }
            weighted = rubric.weighted(playbook.rubricWeights)
            verdict = rubric.verdict(weights: playbook.rubricWeights).rawValue
        } catch {
            failure = "\(error)"
        }
        let record = EvalRecord(file: item.file, expectedGenres: item.expectedGenres, predictedGenre: predicted,
                                humanScore: item.humanScore, weighted: weighted, verdict: verdict,
                                scoutSeconds: scoutTime, judgeSeconds: judgeTime,
                                promptTokens: usage?.prompt, completionTokens: usage?.completion, error: failure)
        records.append(record)
        print(String(format: "[%d/%d] %@ 预期 %@ → %@ · 人工 %.1f · AI %@ %@", index + 1, min(limit, manifest.items.count),
                     item.file, item.expectedGenres.map(\.rawValue).joined(separator: "/"),
                     predicted?.rawValue ?? "—", item.humanScore, weighted.map { String(format: "%.2f", $0) } ?? "—",
                     failure ?? ""))
    }
    summarize(records)
    let out = options.optional("out") ?? "eval/results/\(Int(Date().timeIntervalSince1970)).json"
    try FileManager.default.createDirectory(at: URL(fileURLWithPath: out).deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(records).write(to: URL(fileURLWithPath: out))
    print("结果 → \(out)")
}

private func summarize(_ records: [EvalRecord]) {
    let done = records.filter { $0.error == nil }
    let labelled = done.filter { !$0.expectedGenres.isEmpty }
    let correct = labelled.filter { r in r.predictedGenre.map { r.expectedGenres.contains($0) } ?? false }.count
    print(String(format: "\n完成 %d/%d · 题材准确率 %.0f%%（%d/%d）", done.count, records.count,
                 labelled.isEmpty ? 0 : Double(correct) / Double(labelled.count) * 100, correct, labelled.count))
    let scored = done.compactMap { r in r.weighted.map { (human: r.humanScore, ai: $0) } }
    if scored.count >= 3 {
        let median = scored.map(\.human).sorted()[scored.count / 2]
        let good = scored.filter { $0.human >= median }.map(\.ai), bad = scored.filter { $0.human < median }.map(\.ai)
        print(String(format: "Spearman（AI 加权分 vs 人工分）%.3f · AUC（好/差区分）%.3f",
                     EvalMetrics.spearman(scored.map(\.ai), scored.map(\.human)), EvalMetrics.auc(positives: good, negatives: bad)))
    }
    let judge = done.compactMap(\.judgeSeconds), scout = done.compactMap(\.scoutSeconds)
    if !judge.isEmpty {
        print(String(format: "平均延迟 scout %.1fs · judge %.1fs · token %d/%d", scout.reduce(0, +) / Double(scout.count),
                     judge.reduce(0, +) / Double(judge.count), done.compactMap(\.promptTokens).reduce(0, +),
                     done.compactMap(\.completionTokens).reduce(0, +)))
    }
    let matrix = EvalMetrics.confusion(expected: labelled.compactMap { $0.expectedGenres.first },
                                       predicted: labelled.compactMap(\.predictedGenre))
    for (expected, row) in matrix.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
        print("  \(expected.rawValue) → " + row.sorted { $0.value > $1.value }.map { "\($0.key.rawValue)×\($0.value)" }.joined(separator: " "))
    }
}

private func seconds(since start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}
