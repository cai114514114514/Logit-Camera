@preconcurrency import AVFoundation
import CameraCore
import Foundation

extension CaptureSession {
    func setRatio(_ ratio: FrameRatio) {
        queue.async {
            // 画幅只影响裁切，任何时候都可以改（AI 方案的画幅不能因相机正在调整而被丢弃）。
            self.state.ratio = ratio
            self.publish()
        }
    }

    /// 当前镜头与格式的能力范围，供模型校验方案与本机曝光程序使用。
    func currentLimits() async -> CameraLimits? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.device.map { self.cameraLimits($0) })
            }
        }
    }

    private func cameraLimits(_ device: AVCaptureDevice) -> CameraLimits {
        let format = device.activeFormat
        let modes = ApertureSupport.exposureModes(device)
        let aperture = ApertureSupport.range(for: device)
        return CameraLimits(
            minAperture: Double(aperture?.minimum ?? device.lensAperture),
            maxAperture: Double(aperture?.maximum ?? device.lensAperture),
            apertureStops: aperture?.stops.map(Double.init) ?? [],
            minISO: Double(format.minISO), maxISO: Double(format.maxISO),
            minShutter: format.minExposureDuration.seconds, maxShutter: format.maxExposureDuration.seconds,
            minZoom: Double(state.minZoom), maxZoom: Double(state.maxZoom),
            minBias: Double(state.minimumBias), maxBias: Double(state.maximumBias), exposureModes: modes,
            lensStops: state.lensStops.map(\.focalLength)
        )
    }
}
