import Foundation

enum CameraValidationError: LocalizedError {
    case invalidValue(String)
    case invalidHardwareRange(String)
    case unsupportedExposureMode
    case ineffectiveExposureBias
    case missingSettings
    case unexpectedSettings
    case invalidReason
    case captureDuringAdjustment

    var errorDescription: String? {
        switch self {
        case .invalidValue(let name):
            "\(name)无效或超出设备支持范围。"
        case .invalidHardwareRange(let name):
            "设备报告的\(name)范围无效。"
        case .unsupportedExposureMode:
            "设备不支持这组自动与手动曝光设置。"
        case .ineffectiveExposureBias:
            "全手动曝光时，曝光补偿必须为零。"
        case .missingSettings:
            "调整操作缺少相机参数。"
        case .unexpectedSettings:
            "保持操作不能携带待应用参数。"
        case .invalidReason:
            "调整理由不能为空，且不能超过 300 字。"
        case .captureDuringAdjustment:
            "调整参数后须重新确认画面，不能同时请求拍摄。"
        }
    }
}
