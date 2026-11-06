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

    func beginAgent(_ token: UUID) {
        queue.async {
            self.cancelAgentLocked()
            self.agentToken = token
        }
    }

    func cancelAgent() { queue.async { self.cancelAgentLocked() } }

    func cancelAgentLocked() {
        agentToken = nil
        if agentCompletion != nil {
            // Cancel the agent's await, not the already issued hardware movement.
            // The shutter stays gated until its callback or a session reset.
            finishAgentApplication(.failure(CancellationError()))
        }
    }

    func observation() async throws -> CameraObservation {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard self.state.phase == .ready, let device = self.device else {
                        throw AIError.message("相机尚未就绪。")
                    }
                    let frame = try self.frames.snapshot()
                    let actual = ExposureReading(aperture: Double(device.lensAperture), iso: Double(device.iso),
                                                 shutterSeconds: device.exposureDuration.seconds,
                                                 zoom: Double(device.videoZoomFactor), exposureBias: Double(device.exposureTargetBias),
                                                 apertureAuto: device.automaticallyAdjustsLensAperture,
                                                 isoAuto: device.automaticallyAdjustsISO,
                                                 shutterAuto: device.automaticallyAdjustsExposureDuration,
                                                 adjustingExposure: device.isAdjustingExposure, adjustingFocus: device.isAdjustingFocus)
                    continuation.resume(returning: CameraObservation(frame: frame, context: ObservationContext(
                        settings: self.state.settings, actual: actual, limits: self.cameraLimits(device)
                    )))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func apply(_ settings: CameraSettings, token: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard self.agentToken == token else { throw CancellationError() }
                    guard self.state.canCapture, let device = self.device else {
                        throw AIError.message("相机正在拍照或调整，稍后重新观察。")
                    }
                    try settings.validate(against: self.cameraLimits(device))
                    let aperture = settings.aperture.map(Float.init) ?? AVCaptureDevice.autoLensAperture
                    let iso = settings.iso.map(Float.init) ?? AVCaptureDevice.autoISO
                    let duration = settings.shutterSeconds.map { CMTime(seconds: $0, preferredTimescale: 1_000_000_000) }
                        ?? AVCaptureDevice.autoExposureDuration
                    let automatic = settings.aperture == nil && settings.iso == nil && settings.shutterSeconds == nil
                    if !automatic {
                        guard device.activeFormat.supportsExposureModeCustom(lensAperture: aperture, duration: duration, iso: iso)
                        else { throw CameraFailure.unsupportedAperture }
                    }
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    self.exposureRevision += 1
                    let operation = UUID()
                    self.agentHardwareID = operation
                    self.agentCompletion = (operation, { continuation.resume(with: $0) })
                    self.state.isApplying = true
                    self.state.selectedAperture = settings.aperture.map(Float.init)
                    self.state.selectedISO = settings.iso
                    self.state.selectedShutter = settings.shutterSeconds
                    self.state.ratio = settings.ratio
                    device.ramp(toVideoZoomFactor: CGFloat(settings.zoom), withRate: Self.zoomRampRate)
                    device.setExposureTargetBias(Float(settings.exposureBias), completionHandler: nil)
                    self.publish()
                    if automatic {
                        device.exposureMode = .continuousAutoExposure
                        self.agentHardwareID = nil
                        self.state.isApplying = false
                        self.readExposure()
                        self.finishAgentApplication(.success(()))
                    } else {
                        device.setExposureModeCustom(lensAperture: aperture, duration: duration, iso: iso) { [weak self = self] _ in
                            guard let self else { return }
                            self.queue.async {
                                guard self.agentHardwareID == operation else { return }
                                self.agentHardwareID = nil
                                self.state.isApplying = false
                                self.readExposure()
                                self.finishAgentApplication(self.agentToken == token ? .success(()) : .failure(CancellationError()))
                            }
                        }
                        self.queue.asyncAfter(deadline: .now() + 5) {
                            guard self.agentHardwareID == operation else { return }
                            self.agentHardwareID = nil
                            self.state.isApplying = false
                            self.state.phase = .unavailable
                            self.needsExposureReset = true
                            self.state.message = "硬件调整超时，请重新连接相机以恢复自动曝光。"
                            self.stopMetering()
                            self.readExposure()
                            self.finishAgentApplication(.failure(AIError.message("硬件调整超时，将重新观察实际状态。")))
                        }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func finishAgentApplication(_ result: Result<Void, Error>) {
        guard let pending = agentCompletion else { return }
        agentCompletion = nil
        pending.finish(result)
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
