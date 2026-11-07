import Foundation

/// 连拍中一张照片的本机质量指标；拿不到的指标为 nil。
public struct FrameQuality: Codable, Sendable, Equatable {
    public var sharpness: Double?
    public var eyesOpen: Double?
    public var faceQuality: Double?
    public var aesthetics: Double?

    public init(sharpness: Double? = nil, eyesOpen: Double? = nil, faceQuality: Double? = nil, aesthetics: Double? = nil) {
        self.sharpness = sharpness
        self.eyesOpen = eyesOpen
        self.faceQuality = faceQuality
        self.aesthetics = aesthetics
    }
}

/// 连拍选片（规格 §6.3）：每项指标组内归一化（跨度不小于该指标的最小跨度），按题材加权；缺失的指标不参与。
public enum BurstSelector {
    private enum Metric: CaseIterable {
        case sharpness, eyesOpen, faceQuality, aesthetics

        /// 归一化的最小跨度：组内差异小于它时按比例计分，避免把微小差异放大成满分差距。
        var minimumSpan: Double {
            switch self {
            case .sharpness: 0.2
            case .eyesOpen, .faceQuality: 0.3
            case .aesthetics: 0.5
            }
        }

        func value(_ frame: FrameQuality) -> Double? {
            switch self {
            case .sharpness: frame.sharpness
            case .eyesOpen: frame.eyesOpen
            case .faceQuality: frame.faceQuality
            case .aesthetics: frame.aesthetics
            }
        }
    }

    private static func weights(_ genre: GenreID) -> [Metric: Double] {
        switch genre {
        case .portrait, .group: [.faceQuality: 0.35, .eyesOpen: 0.3, .sharpness: 0.25, .aesthetics: 0.1]
        default: [.sharpness: 0.6, .aesthetics: 0.4]
        }
    }

    public static func scores(_ frames: [FrameQuality], genre: GenreID) -> [Double] {
        guard !frames.isEmpty else { return [] }
        let weights = weights(genre)
        var totals = Array(repeating: 0.0, count: frames.count)
        var weightSums = Array(repeating: 0.0, count: frames.count)
        for (metric, weight) in weights {
            let values = frames.map { metric.value($0) }
            let present = values.compactMap { $0 }
            guard let low = present.min(), let high = present.max() else { continue }
            let span = max(high - low, metric.minimumSpan)
            for (index, value) in values.enumerated() {
                guard let value else { continue }
                let normalized = (value - low) / span
                totals[index] += weight * normalized
                weightSums[index] += weight
            }
        }
        return zip(totals, weightSums).map { $1 > 0 ? $0 / $1 : 0 }
    }

    /// 最高分的序号；并列或全部缺失时取最早的一张。
    public static func best(_ frames: [FrameQuality], genre: GenreID) -> Int {
        let values = scores(frames, genre: genre)
        guard var best = values.indices.first else { return 0 }
        for index in values.indices where values[index] > values[best] + 1e-12 { best = index }
        return best
    }
}
