@preconcurrency import AVFoundation
import CameraCore
import Foundation

/// 可变光圈相关的系统接口只在 iOS 27 提供（硬件上目前只有 iPhone 18 Pro 系列主摄）。
/// 所有调用都经过这里：旧系统或固定光圈镜头上，光圈视为固定值，曝光用快门 + ISO 或系统自动。
enum ApertureSupport {
    /// 当前格式的光圈范围；旧系统返回镜头的固定光圈。
    static func range(for device: AVCaptureDevice) -> ApertureRange? {
        if #available(iOS 27.0, *) {
            let format = device.activeFormat
            return ApertureRange(minimum: format.minLensAperture, maximum: format.maxLensAperture,
                                 stops: format.recommendedLensApertureStops)
        }
        return ApertureRange(minimum: device.lensAperture, maximum: device.lensAperture, stops: [device.lensAperture])
    }

    /// 是否支持「光圈优先」（锁定光圈、系统自动快门与 ISO）。旧系统一律不支持。
    static func supportsPriority(_ device: AVCaptureDevice, range: ApertureRange?) -> Bool {
        guard range?.isVariable == true else { return false }
        if #available(iOS 27.0, *) {
            return device.activeFormat.supportsExposureModeCustom(lensAperture: AVCaptureDevice.currentLensAperture,
                                                                   duration: AVCaptureDevice.autoExposureDuration,
                                                                   iso: AVCaptureDevice.autoISO)
        }
        return false
    }

    /// 某个光圈下的光圈优先是否可用。
    static func supportsPriority(_ device: AVCaptureDevice, aperture: Float) -> Bool {
        if #available(iOS 27.0, *) {
            return device.activeFormat.supportsExposureModeCustom(lensAperture: aperture,
                                                                   duration: AVCaptureDevice.autoExposureDuration,
                                                                   iso: AVCaptureDevice.autoISO)
        }
        return false
    }

    /// 设置光圈优先。调用方持有配置锁；旧系统返回 false（不做任何事）。
    static func setPriority(_ device: AVCaptureDevice, aperture: Float,
                            completion: @escaping @Sendable (CMTime) -> Void) -> Bool {
        if #available(iOS 27.0, *) {
            device.setExposureModeCustom(lensAperture: aperture, duration: AVCaptureDevice.autoExposureDuration,
                                         iso: AVCaptureDevice.autoISO, completionHandler: completion)
            return true
        }
        return false
    }

    /// 全手动（光圈 + 快门 + ISO）。不支持时返回 false，调用方改用只设快门与 ISO 的接口。
    static func setManual(_ device: AVCaptureDevice, aperture: Float, duration: CMTime, iso: Float,
                          completion: @escaping @Sendable (CMTime) -> Void) -> Bool {
        if #available(iOS 27.0, *) {
            guard device.activeFormat.supportsExposureModeCustom(lensAperture: aperture, duration: duration, iso: iso)
            else { return false }
            device.setExposureModeCustom(lensAperture: aperture, duration: duration, iso: iso, completionHandler: completion)
            return true
        }
        return false
    }

    /// 曝光模式组合（光圈 / 快门 / ISO 是否自动）。旧系统只报告「全自动」与「快门 + ISO 手动」。
    static func exposureModes(_ device: AVCaptureDevice) -> [ExposureModeSupport] {
        if #available(iOS 27.0, *) {
            let format = device.activeFormat
            var modes: [ExposureModeSupport] = []
            for apertureAuto in [false, true] {
                for shutterAuto in [false, true] {
                    for isoAuto in [false, true] {
                        let allAuto = apertureAuto && shutterAuto && isoAuto
                        let supported = allAuto ? device.isExposureModeSupported(.continuousAutoExposure)
                            : format.supportsExposureModeCustom(
                                lensAperture: apertureAuto ? AVCaptureDevice.autoLensAperture : AVCaptureDevice.currentLensAperture,
                                duration: shutterAuto ? AVCaptureDevice.autoExposureDuration : AVCaptureDevice.currentExposureDuration,
                                iso: isoAuto ? AVCaptureDevice.autoISO : AVCaptureDevice.currentISO)
                        if supported {
                            modes.append(ExposureModeSupport(apertureAuto: apertureAuto, shutterAuto: shutterAuto, isoAuto: isoAuto))
                        }
                    }
                }
            }
            return modes
        }
        var modes: [ExposureModeSupport] = []
        if device.isExposureModeSupported(.continuousAutoExposure) {
            modes.append(ExposureModeSupport(apertureAuto: true, shutterAuto: true, isoAuto: true))
        }
        if device.isExposureModeSupported(.custom) {
            modes.append(ExposureModeSupport(apertureAuto: true, shutterAuto: false, isoAuto: false))
        }
        return modes
    }
}
