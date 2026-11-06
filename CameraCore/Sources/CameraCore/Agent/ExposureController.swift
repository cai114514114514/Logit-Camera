import Foundation

public struct ExposureState: Sendable, Equatable {
    public var bias: Double
    /// 当前实际快门（自动时即自动曝光选出的快门）。
    public var shutterSeconds: Double
    public var shutterLocked: Bool
    public var iso: Double
    public var minISO: Double
    public var minBias: Double
    public var maxBias: Double

    public init(bias: Double, shutterSeconds: Double, shutterLocked: Bool, iso: Double, minISO: Double,
                minBias: Double, maxBias: Double) {
        self.bias = bias
        self.shutterSeconds = shutterSeconds
        self.shutterLocked = shutterLocked
        self.iso = iso
        self.minISO = minISO
        self.minBias = minBias
        self.maxBias = maxBias
    }
}

public enum ExposureCommand: Equatable, Sendable {
    case none
    case setBias(Double)
    /// 固定快门、ISO 自动。
    case lockShutter(seconds: Double)
    case releaseShutter
}

/// 曝光闭环（每秒约 10 次）：在系统自动曝光之上，用 EV 补偿把主体推向方案的目标亮度，
/// 并在自动快门过慢时锁定最慢快门。每步最多 0.1 EV，死区 ±0.1 EV。
public struct ExposureController: Sendable {
    /// 中灰在 sRGB 编码下约为 0.46。
    public static let middleGray = 0.46
    public static let step = 0.1
    public static let deadband = 0.1

    public private(set) var settled = false
    private var settledFrames = 0
    /// ISO 触顶后释放了快门锁：本方案内不再锁定，避免来回切换。
    private var ceilingBlocked = false

    public init() {}

    public mutating func reset() {
        settled = false
        settledFrames = 0
        ceilingBlocked = false
    }

    public mutating func step(_ m: SceneMeasurement, intent: ExposureIntent, state: ExposureState) -> ExposureCommand {
        if let command = shutterCommand(intent: intent, state: state) { return command }

        let measured: Double = switch intent.meter {
        case .subject: m.luminance.subjectMean ?? m.luminance.mean
        case .scene, .highlights: m.luminance.mean
        }
        guard measured > 0.001 else { return hold(atLimit: true) }
        let error = log2(measured / Self.middleGray) - intent.subjectEV

        var delta: Double
        if m.luminance.clipHigh > intent.highlightClipMax {
            delta = -Self.step
        } else if abs(error) <= Self.deadband {
            return hold(atLimit: false, settledNow: true)
        } else {
            delta = min(max(-error, -Self.step), Self.step)
            if delta > 0, m.luminance.clipHigh >= intent.highlightClipMax * 0.8 { delta = 0 }
        }
        guard delta != 0 else { return hold(atLimit: false) }
        let target = min(max(state.bias + delta, state.minBias), state.maxBias)
        guard abs(target - state.bias) > 1e-6 else { return hold(atLimit: true) }
        settled = false
        settledFrames = 0
        return .setBias((target * 100).rounded() / 100)
    }

    private mutating func shutterCommand(intent: ExposureIntent, state: ExposureState) -> ExposureCommand? {
        guard let floor = intent.shutterFloor else { return state.shutterLocked ? .releaseShutter : nil }
        if state.shutterLocked {
            if let ceiling = intent.isoCeiling, state.iso >= ceiling {
                ceilingBlocked = true
                return .releaseShutter
            }
            // ISO 已回到最低值附近（1/3 档内），说明光线足够，交还自动快门。
            if state.iso <= state.minISO * pow(2, 1.0 / 3) { return .releaseShutter }
            return nil
        }
        if !ceilingBlocked, state.shutterSeconds > floor * 1.05 { return .lockShutter(seconds: floor) }
        return nil
    }

    private mutating func hold(atLimit: Bool, settledNow: Bool = false) -> ExposureCommand {
        if atLimit || settledNow {
            settledFrames += 1
            settled = settledFrames >= 3
        } else {
            settledFrames = 0
            settled = false
        }
        return .none
    }
}
