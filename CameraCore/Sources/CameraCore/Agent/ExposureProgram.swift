import Foundation

/// 当前硬件实际的曝光参数（读回值，不是请求值）。
public struct ExposureReading: Sendable, Equatable {
    public var aperture: Double
    public var shutter: Double
    public var iso: Double

    public init(aperture: Double, shutter: Double, iso: Double) {
        self.aperture = aperture
        self.shutter = shutter
        self.iso = iso
    }
}

/// 当前镜头的曝光能力。
public struct ExposureLimits: Sendable, Equatable {
    public var minISO: Double
    public var maxISO: Double
    public var minShutter: Double
    public var maxShutter: Double
    public var apertureStops: [Double]
    public var variableAperture: Bool

    public init(minISO: Double, maxISO: Double, minShutter: Double, maxShutter: Double,
                apertureStops: [Double], variableAperture: Bool) {
        self.minISO = minISO
        self.maxISO = maxISO
        self.minShutter = minShutter
        self.maxShutter = maxShutter
        self.apertureStops = apertureStops
        self.variableAperture = variableAperture
    }
}

/// 选择快门所需的运动信息。
public struct ExposureContext: Sendable, Equatable {
    /// 当前镜头的等效焦距（mm）。
    public var focalLength: Double
    public var deviceAngularSpeed: Double
    /// 主体中心的速度（归一化画面 / 秒）。
    public var subjectSpeed: Double
    public var isNight: Bool

    public init(focalLength: Double, deviceAngularSpeed: Double, subjectSpeed: Double, isNight: Bool = false) {
        self.focalLength = focalLength
        self.deviceAngularSpeed = deviceAngularSpeed
        self.subjectSpeed = subjectSpeed
        self.isNight = isNight
    }
}

/// 要写入硬件的全手动参数。`aperture` 为 nil 表示不改光圈（固定光圈镜头）。
public struct ExposureTarget: Sendable, Equatable {
    public var aperture: Double?
    public var shutter: Double
    public var iso: Double

    public init(aperture: Double?, shutter: Double, iso: Double) {
        self.aperture = aperture
        self.shutter = shutter
        self.iso = iso
    }
}

public struct ExposureDecision: Sendable, Equatable {
    /// nil 表示保持当前参数。
    public var target: ExposureTarget?
    public var settled: Bool
    /// ISO 已到上限、快门已到最慢，仍然欠曝。
    public var starved: Bool
    /// 测得亮度与目标的差（EV，正数表示需要更亮）。
    public var errorEV: Double
}

/// 本机曝光程序：把曝光意图换算成光圈、快门、ISO（规格 §5.2）。每秒约 10 次，纯函数加少量状态。
public struct ExposureProgram: Sendable {
    public static let gain = 0.6
    public static let maxStep = 1.0
    public static let deadband = 1.0 / 6
    public static let settleBand = 1.0 / 3
    public static let defaultISOCeiling = 1600.0
    public static let nightISOCeiling = 6400.0
    /// 18% 线性中灰。
    public static let middleGray = 0.18

    private var settledFrames = 0

    public init() {}

    public mutating func reset() { settledFrames = 0 }

    /// sRGB 编码值 → 线性亮度。
    public static func linear(_ encoded: Double) -> Double {
        let v = min(max(encoded, 0), 1)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// 偏好快门与允许的最慢快门（秒）。
    public static func shutterRange(intent: ExposureIntent, context: ExposureContext,
                                    limits: ExposureLimits) -> (preferred: Double, slowest: Double) {
        let focal = max(context.focalLength, 1)
        let handheld = min(max(1 / (2 * focal), 1.0 / 500), 1.0 / 30)
        let still = context.deviceAngularSpeed < 0.03
        var slowest = still ? min(handheld * 4, 1.0 / 8) : handheld
        let speed = context.subjectSpeed
        var preferred: Double
        switch intent.motion {
        case .freeze:
            preferred = min(max(0.0015 / max(speed, 0.006), 1.0 / 2000), 1.0 / 250)
            slowest = preferred
        case .normal:
            preferred = min(handheld, 0.003 / max(speed, 0.003))
        case .blur:
            preferred = context.deviceAngularSpeed < 0.05 ? 1.0 / 15 : handheld
            slowest = max(slowest, preferred)
        }
        if intent.shutterFloor > 0 {
            slowest = intent.shutterFloor
            preferred = min(preferred, slowest)
        }
        preferred = min(max(preferred, limits.minShutter), limits.maxShutter)
        slowest = min(max(slowest, preferred), limits.maxShutter)
        return (preferred, slowest)
    }

    /// 景深 → 光圈；不可变光圈的镜头返回 nil。
    public static func aperture(for depth: DepthIntent, limits: ExposureLimits) -> Double? {
        guard limits.variableAperture, let widest = limits.apertureStops.min() else { return nil }
        switch depth {
        case .shallow, .normal:
            return widest
        case .deep:
            return limits.apertureStops.min { abs($0 - 4) < abs($1 - 4) } ?? widest
        }
    }

    public mutating func step(luminance: LuminanceStats, intent: ExposureIntent, reading: ExposureReading,
                              limits: ExposureLimits, context: ExposureContext, writePending: Bool) -> ExposureDecision {
        let encoded: Double = switch intent.meter {
        case .subject: luminance.subjectMean ?? luminance.mean
        case .scene, .highlights: luminance.mean
        }
        let measured = Self.linear(encoded)
        let target = Self.middleGray * pow(2, intent.subjectEV)
        var error = log2(target / max(measured, 1e-4))
        if luminance.clipHigh > intent.highlightClipMax {
            error = min(error, -Self.settleBand)
        } else if error > 0, luminance.clipHigh >= intent.highlightClipMax * 0.8, intent.highlightClipMax > 0 {
            error = 0
        }

        let aperture = Self.aperture(for: intent.depth, limits: limits)
        let ceiling = intent.isoCeiling > 0 ? intent.isoCeiling
            : (context.isNight ? Self.nightISOCeiling : Self.defaultISOCeiling)
        let isoCap = min(max(ceiling, limits.minISO), limits.maxISO)
        let range = Self.shutterRange(intent: intent, context: context, limits: limits)

        // 本次要校正的量：比例控制、限幅；死区内或上一次写入未生效时不校正。
        var correction = abs(error) <= Self.deadband ? 0 : min(max(Self.gain * error, -Self.maxStep), Self.maxStep)
        if writePending { correction = 0 }

        let n = aperture ?? reading.aperture
        let currentLight = reading.shutter * reading.iso / (reading.aperture * reading.aperture)
        let light = currentLight * pow(2, correction)

        var shutter = range.preferred
        var iso = light * n * n / shutter
        var starved = false
        if iso > isoCap {
            shutter = min(range.slowest, light * n * n / isoCap)
            iso = light * n * n / shutter
            if iso > isoCap {
                iso = isoCap
                starved = error > Self.settleBand
            }
        }
        if iso < limits.minISO {
            iso = limits.minISO
            shutter = max(light * n * n / iso, limits.minShutter)
        }
        shutter = min(max(shutter, limits.minShutter), limits.maxShutter)
        iso = min(max(iso, limits.minISO), limits.maxISO)

        let proposal = ExposureTarget(aperture: aperture, shutter: shutter, iso: iso)
        let atLimit = starved || (error < 0 && iso <= limits.minISO + 0.5 && shutter <= limits.minShutter * 1.01)
        if abs(error) <= Self.settleBand || atLimit {
            settledFrames += 1
        } else {
            settledFrames = 0
        }
        let settled = settledFrames >= 2
        let changed = Self.differs(proposal, from: reading)
        return ExposureDecision(target: writePending || !changed ? nil : proposal, settled: settled,
                                starved: starved, errorEV: error)
    }

    /// 参数与当前读回值差别超过 1/6 档（或光圈不同）才写入，避免反复写同一组值。
    private static func differs(_ target: ExposureTarget, from reading: ExposureReading) -> Bool {
        if let aperture = target.aperture, abs(aperture - reading.aperture) > 0.05 { return true }
        let shutterStops = abs(log2(target.shutter / max(reading.shutter, 1e-6)))
        let isoStops = abs(log2(target.iso / max(reading.iso, 1e-6)))
        return shutterStops > deadband || isoStops > deadband
    }
}
