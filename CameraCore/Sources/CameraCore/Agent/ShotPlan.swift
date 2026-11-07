import Foundation

public struct SizeRange: Codable, Sendable, Equatable {
    public var min: Double
    public var max: Double

    public init(min: Double, max: Double) {
        self.min = min
        self.max = max
    }

    public var midpoint: Double { (min + max) / 2 }
}

public struct Composition: Codable, Sendable, Equatable {
    public var ratio: FrameRatio
    /// 主体中心在裁切框中的目标位置。
    public var anchor: NormalizedPoint
    /// 主体高度占裁切框高度的范围。
    public var subjectSize: SizeRange
    /// 裁切面积下限（相对传感器面积）。
    public var minCropArea: Double
    public var levelHorizon: Bool

    public init(ratio: FrameRatio, anchor: NormalizedPoint, subjectSize: SizeRange,
                minCropArea: Double = 0.25, levelHorizon: Bool) {
        self.ratio = ratio
        self.anchor = anchor
        self.subjectSize = subjectSize
        self.minCropArea = minCropArea
        self.levelHorizon = levelHorizon
    }
}

public enum MeterMode: String, Codable, Sendable {
    case subject, highlights, scene
}

/// 动作意图：决定快门策略。
public enum MotionIntent: String, Codable, Sendable, CaseIterable {
    /// 冻结动作。
    case freeze
    /// 手持安全即可。
    case normal
    /// 允许拖影（仅在手机稳定时生效）。
    case blur
}

/// 景深意图：只影响可变光圈的主摄。
public enum DepthIntent: String, Codable, Sendable, CaseIterable {
    case shallow, normal, deep
}

/// 焦段意图：等效焦距（mm），0 表示用题材默认值。本机吸附到最近的物理镜头档。
public struct LensIntent: Codable, Sendable, Equatable {
    public var focalLength: Double

    public init(focalLength: Double) {
        self.focalLength = focalLength
    }
}

/// 曝光意图：目标与风格，而不是固定参数。具体的光圈、快门、ISO 由本机曝光程序实时决定。
public struct ExposureIntent: Codable, Sendable, Equatable {
    public var meter: MeterMode
    /// 主体相对 18% 线性中灰的目标亮度（EV）。
    public var subjectEV: Double
    public var highlightClipMax: Double
    public var motion: MotionIntent
    public var depth: DepthIntent
    /// 最慢快门（秒）；0 表示由程序决定。
    public var shutterFloor: Double
    /// ISO 上限；0 表示由程序决定。
    public var isoCeiling: Double

    public init(meter: MeterMode, subjectEV: Double, highlightClipMax: Double, motion: MotionIntent = .normal,
                depth: DepthIntent = .normal, shutterFloor: Double = 0, isoCeiling: Double = 0) {
        self.meter = meter
        self.subjectEV = subjectEV
        self.highlightClipMax = highlightClipMax
        self.motion = motion
        self.depth = depth
        self.shutterFloor = shutterFloor
        self.isoCeiling = isoCeiling
    }
}

/// 时机信号：让这一刻更好的条件（加分项，不是前提）。JSON：`{"kind":"eyesOpen","threshold":0.6}`。
public enum Trigger: Sendable, Equatable {
    case subjectSharp(min: Double)
    case eyesOpen(min: Double)
    case faceToward(maxYaw: Double)
    case horizonLevel(maxDegrees: Double)
    case deviceStill(maxRadPerSec: Double)
    case subjectPlaced(maxError: Double)
    case highlightsSafe(maxClip: Double)

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case subjectSharp, eyesOpen, faceToward, horizonLevel, deviceStill, subjectPlaced, highlightsSafe

        /// 阈值的合法范围。
        public var validRange: ClosedRange<Double> {
            switch self {
            case .subjectSharp, .eyesOpen: 0...1
            case .faceToward, .horizonLevel: 0...45
            case .deviceStill: 0...2
            case .subjectPlaced: 0...0.5
            case .highlightsSafe: 0...0.05
            }
        }

        /// 供提示词与工具描述使用的范围文字，例如「faceToward 0–45」。
        public var rangeText: String {
            func f(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
            return "\(rawValue) \(f(validRange.lowerBound))–\(f(validRange.upperBound))"
        }
    }

    public init(kind: Kind, threshold: Double) {
        switch kind {
        case .subjectSharp: self = .subjectSharp(min: threshold)
        case .eyesOpen: self = .eyesOpen(min: threshold)
        case .faceToward: self = .faceToward(maxYaw: threshold)
        case .horizonLevel: self = .horizonLevel(maxDegrees: threshold)
        case .deviceStill: self = .deviceStill(maxRadPerSec: threshold)
        case .subjectPlaced: self = .subjectPlaced(maxError: threshold)
        case .highlightsSafe: self = .highlightsSafe(maxClip: threshold)
        }
    }

    public var kind: Kind {
        switch self {
        case .subjectSharp: .subjectSharp
        case .eyesOpen: .eyesOpen
        case .faceToward: .faceToward
        case .horizonLevel: .horizonLevel
        case .deviceStill: .deviceStill
        case .subjectPlaced: .subjectPlaced
        case .highlightsSafe: .highlightsSafe
        }
    }

    public var threshold: Double {
        switch self {
        case .subjectSharp(let v), .eyesOpen(let v), .faceToward(let v), .horizonLevel(let v),
             .deviceStill(let v), .subjectPlaced(let v), .highlightsSafe(let v): v
        }
    }
}

extension Trigger: Codable {
    private enum CodingKeys: String, CodingKey { case kind, threshold }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        self.init(kind: kind, threshold: try container.decode(Double.self, forKey: .threshold))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(threshold, forKey: .threshold)
    }
}

/// 宽松解码：已取消的种类（exposureSettled、subjectPresent）、未知种类或缺阈值的条目被忽略。
private struct LenientTrigger: Decodable {
    let trigger: Trigger?

    private enum CodingKeys: String, CodingKey { case kind, threshold }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let raw = try? container.decode(String.self, forKey: .kind), let kind = Trigger.Kind(rawValue: raw),
              let threshold = try? container.decode(Double.self, forKey: .threshold) else {
            trigger = nil
            return
        }
        trigger = Trigger(kind: kind, threshold: threshold)
    }
}

public enum PlanValidationError: Error, Equatable, Sendable {
    /// 带字段名与合法范围的文字，原样反馈给模型。
    case outOfRange(String)
    case invalidRange(String)

    public var detail: String {
        switch self {
        case .outOfRange(let text): "超出范围：\(text)"
        case .invalidRange(let text): "范围无效：\(text)"
        }
    }
}

/// 导演（模型）给出的拍摄意图。本机据此选镜头、曝光、构图并判断时机。
public struct ShotPlan: Codable, Sendable, Equatable {
    public var id: UUID
    public var genre: GenreID
    public var genreConfidence: Double
    public var subject: SubjectKind
    public var composition: Composition
    public var lens: LensIntent
    public var exposure: ExposureIntent
    public var moment: [Trigger]
    public var holdMs: Int
    public var rationale: String
    /// 子项目 3（意图）预留。
    public var intentWeights: [String: Double]?
    /// 子项目 C（滤镜）预留。
    public var look: String?

    public static let shutterFloorRange: ClosedRange<Double> = 1.0 / 1000...1
    public static let isoCeilingRange: ClosedRange<Double> = 100...12800

    public init(id: UUID = UUID(), genre: GenreID, genreConfidence: Double, subject: SubjectKind,
                composition: Composition, lens: LensIntent = LensIntent(focalLength: 0), exposure: ExposureIntent,
                moment: [Trigger], holdMs: Int = 200, rationale: String,
                intentWeights: [String: Double]? = nil, look: String? = nil) {
        self.id = id
        self.genre = genre
        self.genreConfidence = genreConfidence
        self.subject = subject
        self.composition = composition
        self.lens = lens
        self.exposure = exposure
        self.moment = moment
        self.holdMs = holdMs
        self.rationale = rationale
        self.intentWeights = intentWeights
        self.look = look
    }

    private enum CodingKeys: String, CodingKey {
        case id, genre, genreConfidence, subject, composition, lens, exposure, moment, holdMs, rationale, intentWeights, look
    }

    /// 知识库默认方案与模型输出不带 id / holdMs：缺省时生成新 id、取 200 ms。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        genre = try c.decode(GenreID.self, forKey: .genre)
        genreConfidence = try c.decode(Double.self, forKey: .genreConfidence)
        subject = try c.decode(SubjectKind.self, forKey: .subject)
        composition = try c.decode(Composition.self, forKey: .composition)
        lens = try c.decodeIfPresent(LensIntent.self, forKey: .lens) ?? LensIntent(focalLength: 0)
        exposure = try c.decode(ExposureIntent.self, forKey: .exposure)
        moment = try c.decodeIfPresent([LenientTrigger].self, forKey: .moment)?.compactMap(\.trigger) ?? []
        holdMs = try c.decodeIfPresent(Int.self, forKey: .holdMs) ?? 200
        rationale = try c.decode(String.self, forKey: .rationale)
        intentWeights = try c.decodeIfPresent([String: Double].self, forKey: .intentWeights)
        look = try c.decodeIfPresent(String.self, forKey: .look)
    }

    public func validate(against limits: CameraLimits) throws(PlanValidationError) {
        try check(genreConfidence, in: 0...1, "genreConfidence")
        try check(composition.anchor.x, in: 0...1, "composition.anchor.x")
        try check(composition.anchor.y, in: 0...1, "composition.anchor.y")
        try check(composition.subjectSize.min, in: 0.05...1, "composition.subjectSize.min")
        try check(composition.subjectSize.max, in: 0.05...1, "composition.subjectSize.max")
        guard composition.subjectSize.min <= composition.subjectSize.max else {
            throw .invalidRange("composition.subjectSize min ≤ max")
        }
        try check(composition.minCropArea, in: 0.25...1, "composition.minCropArea")
        try check(exposure.subjectEV, in: -2...2, "exposure.subjectEV")
        try check(exposure.highlightClipMax, in: 0...0.05, "exposure.highlightClipMax")
        if exposure.shutterFloor != 0 { try check(exposure.shutterFloor, in: Self.shutterFloorRange, "exposure.shutterFloor 0 或 0.001–1") }
        if exposure.isoCeiling != 0 { try check(exposure.isoCeiling, in: Self.isoCeilingRange, "exposure.isoCeiling 0 或 100–12800") }
        if lens.focalLength != 0 {
            let range: ClosedRange<Double>
            if let shortest = limits.lensStops.min(), let longest = limits.lensStops.max() {
                range = shortest * 0.8...longest * 1.25
            } else {
                range = 10...300
            }
            try check(lens.focalLength, in: range, "lens.focalLength 0 或 \(Int(range.lowerBound))–\(Int(range.upperBound))")
        }
        try check(Double(holdMs), in: 0...1000, "holdMs")
        for (index, trigger) in moment.enumerated() {
            try check(trigger.threshold, in: trigger.kind.validRange, "moment[\(index)].threshold \(trigger.kind.rangeText)")
        }
        let trimmed = rationale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 120 else { throw .outOfRange("rationale 1–120 字") }
    }

    private func check(_ value: Double, in range: ClosedRange<Double>, _ name: String) throws(PlanValidationError) {
        guard value.isFinite, range.contains(value) else { throw .outOfRange(name) }
    }
}
