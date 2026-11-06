@preconcurrency import AVFoundation
import CameraCore
import Foundation

/// 执行层使用的硬件入口。全部在相机串行队列上执行，失败只上报错误、不抛出。
extension CaptureSession {
    /// 直立全画幅归一化坐标（左上原点）→ 设备兴趣点坐标（后置主摄，取景旋转 90°）。
    static func devicePoint(_ point: CameraCore.NormalizedPoint) -> CGPoint {
        CGPoint(x: point.y, y: 1 - point.x)
    }

    /// 连续自动对焦并把对焦与测光点放在主体上。
    func setSubjectPoint(_ point: CameraCore.NormalizedPoint) {
        queue.async {
            guard self.state.canCapture, let device = self.device else { return }
            let target = Self.devicePoint(point)
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = target }
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = target }
                // 自动或光圈优先时，重新设置模式才会让新的测光点生效；已锁快门时只移动兴趣点。
                if self.state.selectedShutter == nil, self.state.selectedISO == nil {
                    if device.exposureMode == .continuousAutoExposure { device.exposureMode = .continuousAutoExposure }
                }
            } catch { self.onEvent?(.error(error.localizedDescription)) }
        }
    }

    func setAgentBias(_ bias: Double) {
        queue.async {
            guard self.state.canCapture, let device = self.device else { return }
            let value = min(max(Float(bias), device.minExposureTargetBias), device.maxExposureTargetBias)
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.setExposureTargetBias(value, completionHandler: nil)
                self.readExposure()
            } catch { self.onEvent?(.error(error.localizedDescription)) }
        }
    }

    /// 固定快门、ISO 自动，光圈保持当前目标。
    func lockShutter(_ seconds: Double) {
        queue.async {
            guard self.state.canCapture, let device = self.device else { return }
            let aperture = self.state.selectedAperture ?? AVCaptureDevice.autoLensAperture
            let duration = CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
            guard device.activeFormat.supportsExposureModeCustom(lensAperture: aperture, duration: duration,
                                                                 iso: AVCaptureDevice.autoISO) else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                self.exposureRevision += 1
                let revision = self.exposureRevision
                self.state.selectedShutter = seconds
                self.state.isApplying = true
                self.publish()
                device.setExposureModeCustom(lensAperture: aperture, duration: duration, iso: AVCaptureDevice.autoISO) { [weak self = self] _ in
                    guard let self else { return }
                    self.queue.async {
                        guard revision == self.exposureRevision else { return }
                        self.state.isApplying = false
                        self.readExposure()
                    }
                }
            } catch { self.onEvent?(.error(error.localizedDescription)) }
        }
    }

    /// 释放快门锁，回到光圈优先（或全自动）。
    func releaseShutter() {
        queue.async {
            guard self.state.canCapture, let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                try self.applyExposureLocked(self.state.selectedAperture, to: device)
            } catch { self.onEvent?(.error(error.localizedDescription)) }
        }
    }
}
