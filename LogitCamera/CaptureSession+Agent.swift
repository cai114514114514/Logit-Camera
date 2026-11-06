@preconcurrency import AVFoundation
import CameraCore
import Foundation

extension CaptureSession {
    func setRatio(_ ratio: FrameRatio) {
        queue.async {
            guard self.state.canCapture else { return }
            self.state.ratio = ratio
            self.publish()
        }
    }

    /// 当前镜头与格式的能力范围，供模型校验方案。
    func currentLimits() async -> CameraLimits? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.device.map { self.cameraLimits($0) })
            }
        }
    }

    private func cameraLimits(_ device: AVCaptureDevice) -> CameraLimits {
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
                            iso: isoAuto ? AVCaptureDevice.autoISO : AVCaptureDevice.currentISO
                        )
                    if supported { modes.append(ExposureModeSupport(apertureAuto: apertureAuto, shutterAuto: shutterAuto, isoAuto: isoAuto)) }
                }
            }
        }
        return CameraLimits(
            minAperture: Double(format.minLensAperture), maxAperture: Double(format.maxLensAperture),
            apertureStops: format.recommendedLensApertureStops.map(Double.init),
            minISO: Double(format.minISO), maxISO: Double(format.maxISO),
            minShutter: format.minExposureDuration.seconds, maxShutter: format.maxExposureDuration.seconds,
            minZoom: Double(device.minAvailableVideoZoomFactor), maxZoom: min(3, Double(device.maxAvailableVideoZoomFactor)),
            minBias: Double(state.minimumBias), maxBias: Double(state.maximumBias), exposureModes: modes
        )
    }
}
