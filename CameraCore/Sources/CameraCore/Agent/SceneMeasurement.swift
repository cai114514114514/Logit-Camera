import Foundation

/// 直立全画幅归一化坐标：原点左上，x 向右、y 向下，取值 0…1。
public struct NormalizedPoint: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct NormalizedRect: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    public var center: NormalizedPoint { NormalizedPoint(x: x + width / 2, y: y + height / 2) }
    public var area: Double { width * height }

    /// 尺寸不超过 1，位置平移到 0…1 之内。
    public func clamped() -> NormalizedRect {
        let w = min(max(width, 0), 1)
        let h = min(max(height, 0), 1)
        return NormalizedRect(x: min(max(x, 0), 1 - w), y: min(max(y, 0), 1 - h), width: w, height: h)
    }
}

public enum SubjectKind: String, Codable, Sendable, CaseIterable {
    case face, body, salient, none
}

public struct Subject: Codable, Sendable, Equatable {
    public var id: Int
    public var kind: SubjectKind
    public var box: NormalizedRect
    public var confidence: Double
    public var yaw: Double?
    public var pitch: Double?
    public var roll: Double?
    /// 左右眼中较小的睁开程度，0…1。
    public var eyeOpenness: Double?
    public var faceQuality: Double?

    public init(id: Int, kind: SubjectKind, box: NormalizedRect, confidence: Double,
                yaw: Double? = nil, pitch: Double? = nil, roll: Double? = nil,
                eyeOpenness: Double? = nil, faceQuality: Double? = nil) {
        self.id = id
        self.kind = kind
        self.box = box
        self.confidence = confidence
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
        self.eyeOpenness = eyeOpenness
        self.faceQuality = faceQuality
    }
}

public struct LuminanceStats: Codable, Sendable, Equatable {
    /// 64 档归一化直方图（和为 1）。
    public var histogram: [Double]
    /// 高光（≥ 250/255）与暗部（≤ 5/255）溢出比例。
    public var clipHigh: Double
    public var clipLow: Double
    /// 平均亮度与主体平均亮度，0…1。
    public var mean: Double
    public var subjectMean: Double?

    public init(histogram: [Double], clipHigh: Double, clipLow: Double, mean: Double, subjectMean: Double?) {
        self.histogram = histogram
        self.clipHigh = clipHigh
        self.clipLow = clipLow
        self.mean = mean
        self.subjectMean = subjectMean
    }
}

public struct Sharpness: Codable, Sendable, Equatable {
    public var global: Double
    public var subject: Double?

    public init(global: Double, subject: Double?) {
        self.global = global
        self.subject = subject
    }
}

public struct AestheticsHint: Codable, Sendable, Equatable {
    /// 系统美学分（-1…1），只作参考输入。
    public var score: Double
    public var isUtility: Bool
    public var labels: [String]

    public init(score: Double, isUtility: Bool, labels: [String]) {
        self.score = score
        self.isUtility = isUtility
        self.labels = labels
    }
}

/// 本地感知层的一次客观测量。
public struct SceneMeasurement: Codable, Sendable, Equatable {
    public var timestamp: TimeInterval
    public var subjects: [Subject]
    public var primarySubjectID: Int?
    public var luminance: LuminanceStats
    public var sharpness: Sharpness
    public var horizonDegrees: Double?
    public var deviceAngularSpeed: Double
    public var subjectSpeed: Double
    public var sceneChange: Double
    public var aesthetics: AestheticsHint?

    public init(timestamp: TimeInterval, subjects: [Subject], primarySubjectID: Int?,
                luminance: LuminanceStats, sharpness: Sharpness, horizonDegrees: Double?,
                deviceAngularSpeed: Double, subjectSpeed: Double, sceneChange: Double,
                aesthetics: AestheticsHint?) {
        self.timestamp = timestamp
        self.subjects = subjects
        self.primarySubjectID = primarySubjectID
        self.luminance = luminance
        self.sharpness = sharpness
        self.horizonDegrees = horizonDegrees
        self.deviceAngularSpeed = deviceAngularSpeed
        self.subjectSpeed = subjectSpeed
        self.sceneChange = sceneChange
        self.aesthetics = aesthetics
    }

    public var primarySubject: Subject? {
        guard let primarySubjectID else { return nil }
        return subjects.first { $0.id == primarySubjectID }
    }
}
