@preconcurrency import AVFoundation
import CameraCore
import Foundation

/// 执行层使用的硬件入口。全部在相机串行队列上执行，失败只上报错误、不抛出。
/// AI 的写入不置 `isApplying`，因此永远不会阻塞快门。
extension CaptureSession {
    /// 直立全画幅归一化坐标（左上原点）→ 设备兴趣点坐标（后置镜头，取景旋转 90°）。
    static func devicePoint(_ point: CameraCore.NormalizedPoint) -> CGPoint {
        CGPoint(x: point.y, y: 1 - point.x)
    }

    /// 连续自动对焦，对焦点放在主体上。全手动曝光时由本机测光，不再移动测光点。
    func setSubjectPoint(_ point: CameraCore.NormalizedPoint) {
        queue.async {
            guard self.state.phase == .ready, !self.state.isBursting, let device = self.device else { return }
            let target = Self.devicePoint(point)
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = target }
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                if device.exposureMode != .custom, device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = target
                    if device.exposureMode == .continuousAutoExposure { device.exposureMode = .continuousAutoExposure }
                }
            } catch { self.onEvent?(.error(error.localizedDescription)) }
        }
    }

    /// AI 的全手动曝光：主摄可变光圈时连同光圈一起写入，否则只写快门与 ISO。
    func setManualExposure(_ target: ExposureTarget) {
        queue.async {
            guard self.state.phase == .ready, !self.state.isBursting, !self.state.isApplying,
                  let device = self.device else { return }
            let format = device.activeFormat
            let seconds = min(max(target.shutter, format.minExposureDuration.seconds), format.maxExposureDuration.seconds)
            let duration = CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
            let iso = min(max(Float(target.iso), format.minISO), format.maxISO)
            let aperture = target.aperture.map(Float.init)
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                self.agentRevision += 1
                let revision = self.agentRevision
                let done: @Sendable (CMTime) -> Void = { [weak self = self] _ in
                    guard let self else { return }
                    self.queue.async {
                        guard revision == self.agentRevision else { return }
                        self.state.agentWritePending = false
                        self.readExposure()
                    }
                }
                if let aperture, self.state.supportsAperturePriority,
                   ApertureSupport.setManual(device, aperture: aperture, duration: duration, iso: iso, completion: done) {
                    self.state.selectedAperture = aperture
                } else if device.isExposureModeSupported(.custom) {
                    device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: done)
                } else {
                    return
                }
                self.state.agentWritePending = true
                self.state.selectedShutter = seconds
                self.state.selectedISO = Double(iso)
                self.publish()
            } catch { self.onEvent?(.error(error.localizedDescription)) }
        }
    }

    /// AI 停止：回到系统自动曝光（保留用户自己选的光圈优先）。
    func releaseManualExposure() {
        queue.async {
            guard let device = self.device, self.state.phase == .ready else { return }
            self.agentRevision += 1
            self.state.agentWritePending = false
            guard device.exposureMode == .custom else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                try self.applyExposureLocked(nil, to: device)
            } catch { self.onEvent?(.error(error.localizedDescription)) }
        }
    }
}
