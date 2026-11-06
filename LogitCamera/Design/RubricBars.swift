import CameraCore
import SwiftUI

/// 七项量表：分数条 + 证据。
struct RubricBars: View {
    let result: RubricResult
    let weights: [RubricCriterion: Double]
    let genreName: String

    private let anchors = (try? Knowledge.rubricAnchors()) ?? [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(format: "加权 %.1f / 4", result.weighted(weights)))
                    .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                Spacer()
                Text(verdictText).font(.caption).foregroundStyle(verdictColor)
            }
            ForEach(result.scores, id: \.criterion) { score in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(name(score.criterion)).font(.caption.weight(.semibold))
                        if (weights[score.criterion] ?? 0) == 0 {
                            Text("不计分").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(score.score)").font(.system(.caption, design: .monospaced, weight: .semibold))
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.Palette.hairline)
                            Capsule().fill(score.score <= 1 ? Theme.Palette.warning : Theme.Palette.accent)
                                .frame(width: geometry.size.width * CGFloat(score.score) / 4)
                        }
                    }
                    .frame(height: 3)
                    Text(score.evidence).font(.caption2).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityIdentifier("camera.rubric")
    }

    private func name(_ criterion: RubricCriterion) -> String {
        criterion == .genre ? genreName : (anchors[criterion]?.name ?? criterion.rawValue)
    }

    private var verdict: Verdict { result.verdict(weights: weights) }

    private var verdictText: String {
        switch verdict {
        case .approve: "放行"
        case .wait: "等待"
        case .revise: "修改方案"
        }
    }

    private var verdictColor: Color { verdict == .approve ? Theme.Palette.accent : .secondary }
}
