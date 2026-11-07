import Foundation

/// AI 修正参数（规格 §3），坐标为全画幅归一化（左上原点）。
public struct CorrectionParams: Sendable, Equatable {
    public var temperature = 0.0
    public var tint = 0.0
    /// −0.5…0（恢复高光）。
    public var highlights = 0.0
    /// 0…0.35。
    public var shadows = 0.0
    /// 主体补光（EV，0…0.84）。
    public var subjectEV = 0.0
    public var subjectCenter = NormalizedPoint(x: 0.5, y: 0.5)
    /// 相对全画幅短边。
    public var subjectRadius = 0.3
    public var subjectIsFace = false
    /// 天空恢复 0…0.7。
    public var sky = 0.0
    public var horizon = 0.45
    /// 肤色保护强度 0…1。
    public var skin = 0.0
    public var vibrance = 0.0

    public init() {}

    public static let none = CorrectionParams()

    /// 修正层的调色操作。`crop` 为成片的裁切框（取景用 `.full`）；`sensorAspect` 为全画幅宽 / 高。
    public func ops(for crop: NormalizedRect = .full, sensorAspect: Double = 0.75) -> [LookOp] {
        var ops: [LookOp] = []
        if abs(temperature) > 0.005 || abs(tint) > 0.005 {
            ops.append(.whiteBalance(temperature: clamp(temperature, -1, 1), tint: clamp(tint, -1, 1)))
        }
        if highlights < -0.005 || shadows > 0.005 {
            ops.append(.highlightsShadows(highlights: clamp(highlights, -1, 0), shadows: clamp(shadows, -1, 1)))
        }
        if subjectEV > 0.02, crop.width > 0, crop.height > 0 {
            let x = (subjectCenter.x - crop.x) / crop.width
            let y = (subjectCenter.y - crop.y) / crop.height
            if (0...1).contains(x), (0...1).contains(y) {
                // 半径从全画幅短边换算到裁切框短边。
                let fullShort = min(sensorAspect, 1.0)
                let cropShort = min(crop.width * sensorAspect, crop.height)
                let radius = clamp(subjectRadius * fullShort / max(cropShort, 1e-3), 0.05, 1)
                ops.append(.subjectLight(x: x, y: y, radius: radius, amount: clamp(subjectEV, -1, 1)))
            }
        }
        if sky > 0.02, crop.height > 0 {
            let horizonInCrop = (horizon - crop.y) / crop.height
            if horizonInCrop > 0.02 {
                ops.append(.skyRecover(amount: clamp(sky, 0, 1), horizon: clamp(horizonInCrop, 0, 1)))
            }
        }
        if skin > 0.05 {
            ops.append(.hsl([HSLBand(.orange, saturation: -0.06 * skin, luminance: 0.05 * skin)]))
        }
        if vibrance > 0.01 { ops.append(.vibrance(clamp(vibrance, -1, 1))) }
        return ops
    }

    /// 最显著的一项修正，用作字幕。
    public var note: String? {
        if subjectEV >= 0.25 { return subjectIsFace ? "逆光，提亮了人脸" : "逆光，提亮了主体" }
        if sky >= 0.25 { return "压了压天空" }
        if highlights <= -0.25 { return "救回了高光" }
        if abs(temperature) >= 0.06 { return "去掉了偏色" }
        if shadows >= 0.2 { return "提亮了暗部" }
        return nil
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
}

/// 根据测量自动规划修正（规格 §3）。纯函数。
public enum CorrectionPlanner {
    public static func plan(_ m: SceneMeasurement, genre: GenreID?) -> CorrectionParams {
        var p = CorrectionParams()
        let lum = m.luminance
        let night = genre == .night

        if let chroma = m.chroma {
            let warmth = chroma.cr - chroma.cb
            let sunset = warmth > 0 && (genre == .landscape || (chroma.topLuma > 0.55 && warmth > 0.12))
            if abs(warmth) > 0.05, !night, !sunset {
                p.temperature = min(max(-warmth * 1.2, -0.25), 0.25) * 0.5
                p.tint = min(max(-(chroma.cb + chroma.cr), -0.2), 0.2) * 0.5
            }
            if chroma.topLuma > 0.6, chroma.topCb > 0.02 {
                p.sky = min(max((chroma.topLuma - 0.55) * 2, 0), 0.7)
                p.horizon = 0.45
            }
            if chroma.saturation < 0.06, genre != .document { p.vibrance = 0.1 }
        }

        p.highlights = -min(max((lum.clipHigh - 0.002) * 25, 0), 0.5)
        let shadowCap = night ? 0.15 : 0.35
        p.shadows = min((min(max((lum.clipLow - 0.01) * 15, 0), 0.3)) + max(0, 0.3 - lum.mean) * 0.8, shadowCap)

        if let subject = m.primarySubject, let subjectMean = lum.subjectMean, subjectMean > 0.01,
           subjectMean < lum.mean * 0.75 {
            var amount = min(max(log2(lum.mean / subjectMean) * 0.6, 0), 0.7)
            if genre == .portrait { amount *= 1.2 }
            p.subjectEV = amount
            p.subjectCenter = subject.box.center
            let size = max(subject.box.width, subject.box.height)
            p.subjectIsFace = subject.kind == .face
            p.subjectRadius = min(max(size * (subject.kind == .face ? 1.5 : 0.9), 0.08), 1)
        }
        if m.subjects.contains(where: { $0.kind == .face }) { p.skin = 1 }
        return p
    }
}

/// 修正参数的时间平滑（时间常数 0.6 秒；主体中心 0.15 秒），避免画面闪烁。
public struct CorrectionSmoother: Sendable {
    public static let tau: TimeInterval = 0.6
    public static let centerTau: TimeInterval = 0.15

    public private(set) var current = CorrectionParams.none
    private var started = false

    public init() {}

    public mutating func reset() {
        current = .none
        started = false
    }

    public mutating func step(_ target: CorrectionParams, dt: TimeInterval) -> CorrectionParams {
        guard started else {
            started = true
            current = target
            return current
        }
        let a = 1 - exp(-max(dt, 0) / Self.tau)
        let c = 1 - exp(-max(dt, 0) / Self.centerTau)
        func mix(_ x: Double, _ y: Double, _ k: Double) -> Double { x + (y - x) * k }
        var next = current
        next.temperature = mix(current.temperature, target.temperature, a)
        next.tint = mix(current.tint, target.tint, a)
        next.highlights = mix(current.highlights, target.highlights, a)
        next.shadows = mix(current.shadows, target.shadows, a)
        next.subjectEV = mix(current.subjectEV, target.subjectEV, a)
        next.sky = mix(current.sky, target.sky, a)
        next.skin = mix(current.skin, target.skin, a)
        next.vibrance = mix(current.vibrance, target.vibrance, a)
        next.horizon = target.horizon
        // 主体消失时中心留在原处，让补光就地淡出。
        if target.subjectEV > 0 {
            next.subjectCenter = NormalizedPoint(x: mix(current.subjectCenter.x, target.subjectCenter.x, c),
                                                 y: mix(current.subjectCenter.y, target.subjectCenter.y, c))
            next.subjectRadius = mix(current.subjectRadius, target.subjectRadius, c)
            next.subjectIsFace = target.subjectIsFace
        }
        current = next
        return next
    }
}
