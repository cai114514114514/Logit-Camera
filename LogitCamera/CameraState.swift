import Foundation
import CameraCore

enum CameraPhase: Sendable {
    case starting, ready, stopped, denied, unavailable, interrupted
}

struct CameraState: Sendable {
    var phase: CameraPhase = .starting
    var message = "正在启动相机"
    var lensName = "主摄"
    var apertureRange: ApertureRange?
    var supportsAperturePriority = false
    var selectedAperture: Float?
    var selectedISO: Double?
    var selectedShutter: Double?
    var ratio: FrameRatio = .standard
    var zoom: Float = 1
    var aperture: Float?
    var iso: Float?
    var exposureSeconds: Double?
    var exposureBias: Float = 0
    var minimumBias: Float = -2
    var maximumBias: Float = 2
    var isApplying = false
    var isCapturing = false

    var canAdjust: Bool {
        phase == .ready && supportsAperturePriority && !isApplying && !isCapturing
    }

    var canCapture: Bool { phase == .ready && !isApplying && !isCapturing }

    var settings: CameraSettings {
        CameraSettings(ratio: ratio, zoom: Double(zoom), aperture: selectedAperture.map(Double.init),
                       iso: selectedISO, shutterSeconds: selectedShutter, exposureBias: Double(exposureBias))
    }

    var hasManualExposure: Bool { selectedAperture != nil || selectedISO != nil || selectedShutter != nil }
}

struct CapturedPhoto: Sendable, Identifiable {
    let id = UUID()
    let data: Data
    let aperture: Double?
    let iso: Double?
    let exposureSeconds: Double?
}

enum CameraEvent: Sendable {
    case state(CameraState)
    case photo(CapturedPhoto)
    case captureRejected
    case captureFailed(String)
    case error(String)
}

enum CameraFailure: LocalizedError {
    case unavailable, configuration, unsupportedAperture, capture, photoPermission

    var errorDescription: String? {
        switch self {
        case .unavailable: "没有找到后置主摄，请在 iPhone 真机上运行。"
        case .configuration: "无法建立拍摄会话，请关闭其他使用相机的应用后重试。"
        case .unsupportedAperture: "当前镜头或拍摄格式不支持这个光圈与自动曝光组合。"
        case .capture: "没有取得照片，请重试。"
        case .photoPermission: "照片尚未保存。请允许添加到照片图库，或使用分享按钮导出。"
        }
    }
}

enum CameraText {
    static func aperture(_ value: Float?) -> String {
        guard let value, value.isFinite, value > 0 else { return "—" }
        return "ƒ/" + value.formatted(.number.precision(.fractionLength(1...2)))
    }

    static func shutter(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "—" }
        if seconds >= 1 { return seconds.formatted(.number.precision(.fractionLength(0...1))) + "s" }
        return "1/" + String(Int((1 / seconds).rounded()))
    }
}
