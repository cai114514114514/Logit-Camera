@preconcurrency import AVFoundation
import Foundation

extension CaptureSession {
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
    private func applyExposureLocked(_ aperture: Float?, to device: AVCaptureDevice) throws {
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
                    try self.applyExposureLocked(self.state.selectedAperture, to: device)
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
                device.videoZoomFactor = max(1, device.minAvailableVideoZoomFactor)
                device.setExposureTargetBias(0, completionHandler: nil)
                self.state.ratio = .standard
                self.readExposure()
            } catch { self.onEvent?(.error(error.localizedDescription)) }
        }
    }
}
