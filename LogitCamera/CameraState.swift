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
    var minZoom: Float = 1
    var minISO: Float = 50
    var maxISO: Float = 3200
    var minShutter: Double = 1.0 / 8000
    var maxShutter: Double = 1
    var maxZoom: Float = 1
    var aperture: Float?
    var iso: Float?
    var exposureSeconds: Double?
    var exposureBias: Float = 0
    var minimumBias: Float = -2
    var maximumBias: Float = 2
    /// 用户改光圈等需要等待硬件完成的操作；期间不能拍。AI 的曝光写入不使用它。
    var isApplying = false
    var isCapturing = false
    var isBursting = false
    /// AI 的全手动曝光写入尚未生效（不影响拍摄）。
    var agentWritePending = false
    var lensStops: [LensStop] = []
    var activeLens: LensStop?

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
    let id: UUID
    let data: Data
    let aperture: Double?
    let iso: Double?
    let exposureSeconds: Double?

    init(id: UUID = UUID(), data: Data, aperture: Double?, iso: Double?, exposureSeconds: Double?) {
        self.id = id
        self.data = data
        self.aperture = aperture
        self.iso = iso
        self.exposureSeconds = exposureSeconds
    }

    /// 同一张照片换成另一份数据（例如按配方渲染后的成片），id 与拍摄参数不变。
    func replacingData(_ data: Data) -> CapturedPhoto {
        CapturedPhoto(id: id, data: data, aperture: aperture, iso: iso, exposureSeconds: exposureSeconds)
    }

    /// HEIF 文件头（ftyp heic/heix/mif1）。
    var isHEIC: Bool {
        guard data.count > 12 else { return false }
        let brand = String(decoding: data[4..<12], as: UTF8.self)
        return brand.hasPrefix("ftyp") && ["heic", "heix", "mif1", "hevc"].contains(String(brand.dropFirst(4)))
    }
}

enum CameraEvent: Sendable {
    case state(CameraState)
    case photo(CapturedPhoto)
    /// AI 开启时的一组连拍（按拍摄顺序，可能少于请求的张数）。
    case burst([CapturedPhoto])
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

    static func bias(_ value: Float) -> String {
        guard value.isFinite else { return "—" }
        let rounded = (value * 10).rounded() / 10
        if rounded == 0 { return "±0.0" }
        return String(format: "%+.1f", rounded)
    }

    static func zoom(_ value: Float) -> String {
        guard value.isFinite, value > 0 else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0...1))) + "×"
    }
}
