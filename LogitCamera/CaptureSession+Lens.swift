@preconcurrency import AVFoundation
import CameraCore
import Foundation

/// 物理镜头切换（规格 §8 / 计划 Task 1 结论）：虚拟三摄不支持全手动曝光，
/// 所以每颗镜头单独作为会话输入，换镜头时替换输入。显示倍率 = 镜头基准倍率 × 设备变焦倍率。
extension CaptureSession {
    /// 发现可用的物理镜头与镜头档。在相机队列上调用。
    func discoverLenses() {
        let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        let ultraWide = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
        let tele = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back)
        let triple = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
        lensDevices = [:]
        if let wide { lensDevices[.wide] = wide }
        if let ultraWide { lensDevices[.ultraWide] = ultraWide }
        if let tele { lensDevices[.telephoto] = tele }
        let switchOver = triple?.virtualDeviceSwitchOverVideoZoomFactors.map { Double(truncating: $0) } ?? []
        let constituents = Set(triple?.constituentDevices.map(\.deviceType) ?? [])
        state.lensStops = LensStop.stops(
            switchOver: switchOver,
            displayMultiplier: Double(triple?.displayVideoZoomFactorMultiplier ?? 1),
            hasUltraWide: ultraWide != nil && constituents.contains(.builtInUltraWideCamera),
            hasTele: tele != nil && constituents.contains(.builtInTelephotoCamera)
        )
    }

    /// 镜头的基准显示倍率（设备变焦为 1 时）。
    func baseZoom(of lens: LensStop.Lens) -> Double {
        switch lens {
        case .wide: 1
        case .ultraWide: state.lensStops.first { $0.lens == .ultraWide }?.zoomFactor ?? 0.5
        case .telephoto: state.lensStops.first { $0.lens == .telephoto }?.zoomFactor ?? 1
        }
    }

    /// 显示倍率落在哪颗镜头：低于 1× 用超广角，达到长焦档用长焦，其余用主摄（含 2× 裁切）。
    func lens(forDisplayZoom zoom: Double) -> LensStop.Lens {
        if zoom < 0.99, lensDevices[.ultraWide] != nil { return .ultraWide }
        if let tele = state.lensStops.first(where: { $0.lens == .telephoto }), zoom >= tele.zoomFactor - 0.01,
           lensDevices[.telephoto] != nil { return .telephoto }
        return .wide
    }

    var displayZoomRange: ClosedRange<Double> {
        let low = state.lensStops.map(\.zoomFactor).min() ?? 1
        let high = (state.lensStops.map(\.zoomFactor).max() ?? 1) * 2
        return low...max(high, 3)
    }

    /// 把会话输入换成指定镜头。调用方在相机队列上、会话之外调用。
    func attach(_ lens: LensStop.Lens) throws {
        guard let camera = lensDevices[lens] else { throw CameraFailure.unavailable }
        guard camera != device else { return }
        let input = try AVCaptureDeviceInput(device: camera)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let previous = session.inputs
        previous.forEach(session.removeInput)
        guard session.canAddInput(input) else {
            previous.forEach { if session.canAddInput($0) { session.addInput($0) } }
            throw CameraFailure.configuration
        }
        session.addInput(input)
        for connection in [videoOutput.connection(with: .video), photoOutput.connection(with: .video)].compactMap({ $0 })
        where connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        if let dimensions = camera.activeFormat.supportedMaxPhotoDimensions.max(by: {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }) {
            photoOutput.maxPhotoDimensions = dimensions
        }
        device = camera
        currentLens = lens
        exposureRevision += 1
        agentRevision += 1
        state.agentWritePending = false
        state.isApplying = false
        state.selectedAperture = nil
        state.selectedISO = nil
        state.selectedShutter = nil
        describe(camera)
        try camera.lockForConfiguration()
        if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
        if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
        camera.unlockForConfiguration()
    }

    /// 根据当前设备刷新镜头相关的状态。
    func describe(_ camera: AVCaptureDevice) {
        let format = camera.activeFormat
        state.lensName = switch currentLens {
        case .ultraWide: "超广角"
        case .wide: "主摄"
        case .telephoto: "长焦"
        }
        state.apertureRange = ApertureRange(minimum: format.minLensAperture, maximum: format.maxLensAperture,
                                            stops: format.recommendedLensApertureStops)
        state.supportsAperturePriority = state.apertureRange?.isVariable == true
            && format.supportsExposureModeCustom(lensAperture: AVCaptureDevice.currentLensAperture,
                                                 duration: AVCaptureDevice.autoExposureDuration,
                                                 iso: AVCaptureDevice.autoISO)
        state.minISO = format.minISO
        state.maxISO = format.maxISO
        state.minShutter = format.minExposureDuration.seconds
        state.maxShutter = format.maxExposureDuration.seconds
        let range = displayZoomRange
        state.minZoom = Float(range.lowerBound)
        state.maxZoom = Float(range.upperBound)
        state.minimumBias = max(-2, camera.minExposureTargetBias)
        state.maximumBias = min(2, camera.maxExposureTargetBias)
        burstDimensions = format.supportedMaxPhotoDimensions
            .filter { Int64($0.width) * Int64($0.height) <= 24_500_000 }
            .max { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }
    }

    /// 显示倍率（0.5、1、2、4…）。跨镜头时替换输入；同一镜头内 `animated` 用 ramp，双指缩放逐帧直接设置。
    func setZoom(_ display: Double, animated: Bool) {
        queue.async {
            guard self.state.canCapture else { return }
            self.applyZoom(display, animated: animated)
        }
    }

    /// AI 选定的镜头档。
    func setLens(_ stop: LensStop) {
        queue.async {
            guard self.state.phase == .ready, !self.state.isCapturing else { return }
            self.applyZoom(stop.zoomFactor, animated: true)
        }
    }

    /// 相机队列上调用。
    func applyZoom(_ display: Double, animated: Bool) {
        let range = displayZoomRange
        let target = min(max(display, range.lowerBound), range.upperBound)
        let lens = lens(forDisplayZoom: target)
        do {
            if lens != currentLens { try attach(lens) }
            guard let device else { return }
            let factor = CGFloat(min(max(target / baseZoom(of: lens), Double(device.minAvailableVideoZoomFactor)),
                                     Double(device.maxAvailableVideoZoomFactor)))
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if animated {
                device.ramp(toVideoZoomFactor: factor, withRate: Self.zoomRampRate)
            } else {
                device.cancelVideoZoomRamp()
                device.videoZoomFactor = factor
            }
            state.zoom = Float(baseZoom(of: lens) * Double(factor))
            state.activeLens = state.lensStops.min { abs(log($0.zoomFactor / target)) < abs(log($1.zoomFactor / target)) }
            publish()
        } catch {
            onEvent?(.error(error.localizedDescription))
        }
    }

    /// 当前镜头的等效焦距（显示倍率 × 24 mm）。
    var currentFocalLength: Double { Double(state.zoom) * LensStop.mainFocalLength }
}
