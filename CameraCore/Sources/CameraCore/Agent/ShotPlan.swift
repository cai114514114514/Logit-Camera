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

public struct ApertureIntent: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable { case auto, prefer }
    public var mode: Mode
    public var value: Double?

    public init(mode: Mode, value: Double? = nil) {
        self.mode = mode
        self.value = value
    }
}

/// 曝光意图：目标与约束，而不是固定参数。
public struct ExposureIntent: Codable, Sendable, Equatable {
    public var meter: MeterMode
    /// 主体相对中灰的目标亮度（EV）。
    public var subjectEV: Double
    public var highlightClipMax: Double
    public var aperture: ApertureIntent
    /// 最慢快门（秒）；为空表示不限制。
    public var shutterFloor: Double?
    public var isoCeiling: Double?

    public init(meter: MeterMode, subjectEV: Double, highlightClipMax: Double, aperture: ApertureIntent,
                shutterFloor: Double?, isoCeiling: Double?) {
        self.meter = meter
        self.subjectEV = subjectEV
        self.highlightClipMax = highlightClipMax
        self.aperture = aperture
        self.shutterFloor = shutterFloor
        self.isoCeiling = isoCeiling
    }
}

/// 拍摄条件：枚举 + 阈值，由本地逐帧判定。JSON：`{"kind":"eyesOpen","threshold":0.6}`。
public enum Trigger: Sendable, Equatable {
    case subjectSharp(min: Double)
    case eyesOpen(min: Double)
    case faceToward(maxYaw: Double)
    case horizonLevel(maxDegrees: Double)
    case deviceStill(maxRadPerSec: Double)
    case subjectPlaced(maxError: Double)
    case highlightsSafe(maxClip: Double)
    case exposureSettled
    case subjectPresent

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case subjectSharp, eyesOpen, faceToward, horizonLevel, deviceStill
        case subjectPlaced, highlightsSafe, exposureSettled, subjectPresent
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
        case .exposureSettled: .exposureSettled
        case .subjectPresent: .subjectPresent
        }
    }

    public var threshold: Double? {
        switch self {
        case .subjectSharp(let v), .eyesOpen(let v), .faceToward(let v), .horizonLevel(let v),
             .deviceStill(let v), .subjectPlaced(let v), .highlightsSafe(let v): v
        case .exposureSettled, .subjectPresent: nil
        }
    }

    /// 阈值的合法范围；无阈值的条件为 nil。
    var validRange: ClosedRange<Double>? {
        switch self {
        case .subjectSharp, .eyesOpen: 0...1
        case .faceToward, .horizonLevel: 0...45
        case .deviceStill: 0...2
        case .subjectPlaced: 0...0.5
        case .highlightsSafe: 0...0.05
        case .exposureSettled, .subjectPresent: nil
        }
    }
}

extension Trigger: Codable {
    private enum CodingKeys: String, CodingKey { case kind, threshold }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        func value() throws -> Double { try container.decode(Double.self, forKey: .threshold) }
        switch kind {
        case .subjectSharp: self = .subjectSharp(min: try value())
        case .eyesOpen: self = .eyesOpen(min: try value())
        case .faceToward: self = .faceToward(maxYaw: try value())
        case .horizonLevel: self = .horizonLevel(maxDegrees: try value())
        case .deviceStill: self = .deviceStill(maxRadPerSec: try value())
        case .subjectPlaced: self = .subjectPlaced(maxError: try value())
        case .highlightsSafe: self = .highlightsSafe(maxClip: try value())
        case .exposureSettled: self = .exposureSettled
        case .subjectPresent: self = .subjectPresent
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(threshold, forKey: .threshold)
    }
}

public enum PlanValidationError: Error, Equatable, Sendable {
    case outOfRange(String)
    case invalidRange(String)
    case unsupportedAperture
}

/// 导演（模型）给出的拍摄方案。执行层据此对焦、曝光、构图并判断拍摄时机。
public struct ShotPlan: Codable, Sendable, Equatable {
    public var id: UUID
    public var genre: GenreID
    public var genreConfidence: Double
    public var subject: SubjectKind
    public var composition: Composition
    public var exposure: ExposureIntent
    public var triggers: [Trigger]
    public var holdMs: Int
    public var rationale: String
    /// 子项目 3（意图）预留。
    public var intentWeights: [String: Double]?
    /// 子项目 5（动态滤镜）预留。
    public var look: String?

    public init(id: UUID = UUID(), genre: GenreID, genreConfidence: Double, subject: SubjectKind,
                composition: Composition, exposure: ExposureIntent, triggers: [Trigger],
                holdMs: Int = 200, rationale: String, intentWeights: [String: Double]? = nil, look: String? = nil) {
        self.id = id
        self.genre = genre
        self.genreConfidence = genreConfidence
        self.subject = subject
        self.composition = composition
        self.exposure = exposure
        self.triggers = triggers
        self.holdMs = holdMs
        self.rationale = rationale
        self.intentWeights = intentWeights
        self.look = look
    }

    private enum CodingKeys: String, CodingKey {
        case id, genre, genreConfidence, subject, composition, exposure, triggers, holdMs, rationale, intentWeights, look
    }

    /// 知识库默认方案与模型输出不带 id / holdMs：缺省时生成新 id、取 200 ms。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        genre = try c.decode(GenreID.self, forKey: .genre)
        genreConfidence = try c.decode(Double.self, forKey: .genreConfidence)
        subject = try c.decode(SubjectKind.self, forKey: .subject)
        composition = try c.decode(Composition.self, forKey: .composition)
        exposure = try c.decode(ExposureIntent.self, forKey: .exposure)
        triggers = try c.decode([Trigger].self, forKey: .triggers)
        holdMs = try c.decodeIfPresent(Int.self, forKey: .holdMs) ?? 200
        rationale = try c.decode(String.self, forKey: .rationale)
        intentWeights = try c.decodeIfPresent([String: Double].self, forKey: .intentWeights)
        look = try c.decodeIfPresent(String.self, forKey: .look)
    }

    public func validate(against limits: CameraLimits) throws {
        try check(genreConfidence, in: 0...1, "genreConfidence")
        try check(composition.anchor.x, in: 0...1, "anchor")
        try check(composition.anchor.y, in: 0...1, "anchor")
        try check(composition.subjectSize.min, in: 0.05...1, "subjectSize")
        try check(composition.subjectSize.max, in: 0.05...1, "subjectSize")
        guard composition.subjectSize.min <= composition.subjectSize.max else {
            throw PlanValidationError.invalidRange("subjectSize")
        }
        try check(composition.minCropArea, in: 0.25...1, "minCropArea")
        try check(exposure.subjectEV, in: -2...2, "subjectEV")
        try check(exposure.highlightClipMax, in: 0...0.05, "highlightClipMax")
        try check(Double(holdMs), in: 0...1000, "holdMs")
        if exposure.aperture.mode == .prefer {
            guard let value = exposure.aperture.value else { throw PlanValidationError.invalidRange("aperture") }
            guard value.isFinite, value >= limits.minAperture - 0.01, value <= limits.maxAperture + 0.01 else {
                throw PlanValidationError.unsupportedAperture
            }
        }
        if let floor = exposure.shutterFloor {
            try check(floor, in: limits.minShutter...limits.maxShutter, "shutterFloor")
        }
        if let ceiling = exposure.isoCeiling {
            try check(ceiling, in: limits.minISO...max(limits.minISO, limits.maxISO), "isoCeiling")
        }
        for trigger in triggers {
            if let range = trigger.validRange, let value = trigger.threshold {
                try check(value, in: range, "trigger.\(trigger.kind.rawValue)")
            }
        }
        let trimmed = rationale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 120 else { throw PlanValidationError.outOfRange("rationale") }
    }

    private func check(_ value: Double, in range: ClosedRange<Double>, _ name: String) throws {
        guard value.isFinite, range.contains(value) else { throw PlanValidationError.outOfRange(name) }
    }
}
