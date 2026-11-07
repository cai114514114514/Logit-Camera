@preconcurrency import AVFoundation
import CameraCore
import Foundation

extension CaptureSession {
    /// 每秒变化 2^8 倍以内：1× → 3× 约 0.2 秒，平滑而不拖沓。
    static let zoomRampRate: Float = 8

    func setAperture(_ aperture: Float?) {
        queue.async {
            guard self.state.canCapture, let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                try self.applyExposureLocked(aperture, to: device)
            } catch { self.onEvent?(.error(error.localizedDescription)) }
        }
    }

    /// Caller holds the configuration lock and runs on the capture queue.
    /// Reapply after a metering-point change to make the new point effective.
    func applyExposureLocked(_ aperture: Float?, to device: AVCaptureDevice) throws {
        if let aperture {
            guard state.supportsAperturePriority,
                  state.apertureRange?.contains(aperture) == true,
                  device.activeFormat.supportsExposureModeCustom(
                    lensAperture: aperture,
                    duration: AVCaptureDevice.autoExposureDuration,
                    iso: AVCaptureDevice.autoISO
                  ) else { throw CameraFailure.unsupportedAperture }
        } else {
            guard device.isExposureModeSupported(.continuousAutoExposure)
            else { throw CameraFailure.configuration }
        }
        exposureRevision += 1
        let revision = exposureRevision
        state.selectedAperture = aperture
        state.selectedISO = nil
        state.selectedShutter = nil
        if let aperture {
            state.isApplying = true
            publish()
            device.setExposureModeCustom(
                lensAperture: aperture,
                duration: AVCaptureDevice.autoExposureDuration,
                iso: AVCaptureDevice.autoISO
            ) { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    guard revision == self.exposureRevision else { return }
                    self.state.isApplying = false
                    self.readExposure()
                }
            }
        } else {
            device.exposureMode = .continuousAutoExposure
            state.isApplying = false
            readExposure()
        }
    }

    func setExposureBias(_ bias: Float) {
        queue.async {
            guard self.state.canCapture, let device = self.device, bias.isFinite else { return }
            let value = min(max(bias, device.minExposureTargetBias), device.maxExposureTargetBias)
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if self.state.selectedISO != nil || self.state.selectedShutter != nil {
                    try self.applyExposureLocked(self.state.selectedAperture, to: device)
                }
                device.setExposureTargetBias(value, completionHandler: nil)
                self.readExposure()
            } catch { self.onEvent?(.error(error.localizedDescription)) }
        }
    }

    func focus(at point: CGPoint) {
        queue.async {
            guard self.state.canCapture, let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    // 手动 ISO 或快门（通常由 AI 设定）保持不变，只移动测光点；
                    // 自动或光圈优先时重新应用曝光模式，使新的测光点生效。
                    if self.state.selectedISO == nil && self.state.selectedShutter == nil {
                        try self.applyExposureLocked(self.state.selectedAperture, to: device)
                    }
                }
            } catch { self.onEvent?(.error(error.localizedDescription)) }
        }
    }

    func reset() {
        queue.async {
            guard let device = self.device, self.state.canCapture else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5) }
                if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5) }
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                // The metering point must be set before applying exposure mode.
                try self.applyExposureLocked(nil, to: device)
                device.setExposureTargetBias(0, completionHandler: nil)
                self.state.ratio = .standard
            } catch { self.onEvent?(.error(error.localizedDescription)) }
            self.applyZoom(1, animated: false)
            self.readExposure()
        }
    }
}
