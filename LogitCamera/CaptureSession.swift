@preconcurrency import AVFoundation
import CameraCore
import Foundation

/// All mutable capture state belongs to `queue`. The main thread only attaches
/// the immutable session reference to an AVCaptureVideoPreviewLayer.
final class CaptureSession: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "camera.session", qos: .userInitiated)
    let photoOutput = AVCapturePhotoOutput()
    let videoOutput = AVCaptureVideoDataOutput()
    let frames = FrameGrabber()
    private let frameQueue = DispatchQueue(label: "camera.frames", qos: .userInitiated)
    var device: AVCaptureDevice?
    var state = CameraState()
    var onEvent: (@Sendable (CameraEvent) -> Void)?
    var processors: [Int64: PhotoCapture] = [:]
    var exposureRevision = 0
    /// AI 曝光写入的版本号；换镜头或用户接管后旧的完成回调被忽略。
    var agentRevision = 0
    var needsExposureReset = false
    var lensDevices: [LensStop.Lens: AVCaptureDevice] = [:]
    var currentLens: LensStop.Lens = .wide
    var burstDimensions: CMVideoDimensions?
    var bursts: [UUID: BurstCollector] = [:]
    private var configured = false
    private var wantsRunning = false
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        watchSession()
    }

    deinit {
        timer?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func observe(_ handler: @escaping @Sendable (CameraEvent) -> Void) {
        queue.async {
            self.onEvent = handler
            self.publish()
        }
    }

    func start() {
        queue.async {
            self.wantsRunning = true
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                self.startAuthorized()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self = self] allowed in
                    guard let self else { return }
                    self.queue.async {
                        guard self.wantsRunning else { return }
                        if allowed { self.startAuthorized() }
                        else { self.denyAccess() }
                    }
                }
            default:
                self.denyAccess()
            }
        }
    }

    func stop() {
        queue.async {
            self.wantsRunning = false
            self.needsExposureReset = self.needsExposureReset || self.state.isApplying
            self.exposureRevision += 1
            self.state.isApplying = false
            self.timer?.cancel()
            self.timer = nil
            if self.session.isRunning { self.session.stopRunning() }
            self.state.phase = .stopped
            self.state.message = "相机已暂停"
            self.publish()
        }
    }

    private func startAuthorized() {
        guard wantsRunning else { return }
        do {
            if !configured { try configure() }
            if needsExposureReset || state.phase == .unavailable, let device {
                if session.isRunning { session.stopRunning() }
                try device.lockForConfiguration()
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                device.unlockForConfiguration()
                state.selectedAperture = nil
                state.selectedISO = nil
                state.selectedShutter = nil
                state.isApplying = false
                exposureRevision += 1
                needsExposureReset = false
            }
            if !session.isRunning { session.startRunning() }
            guard session.isRunning else { throw CameraFailure.configuration }
            state.phase = .ready
            state.message = state.supportsAperturePriority
                ? "\(state.lensName) · 实时取景" : "\(state.lensName) · 固定光圈"
            startMetering()
            readExposure()
        } catch {
            state.phase = .unavailable
            state.message = error.localizedDescription
            publish()
        }
    }

    private func configure() throws {
        discoverLenses()
        // 物理镜头分别作为输入（虚拟三摄不支持全手动曝光）。默认主摄。
        guard let camera = lensDevices[.wide] else { throw CameraFailure.unavailable }
        let input = try AVCaptureDeviceInput(device: camera)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        guard session.canAddInput(input) else { throw CameraFailure.configuration }
        session.addInput(input)
        guard session.canAddOutput(photoOutput) else {
            session.removeInput(input)
            throw CameraFailure.configuration
        }
        session.addOutput(photoOutput)
        guard session.canAddOutput(videoOutput) else {
            session.removeOutput(photoOutput)
            session.removeInput(input)
            throw CameraFailure.configuration
        }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput.setSampleBufferDelegate(frames, queue: frameQueue)
        session.addOutput(videoOutput)
        if let connection = videoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        photoOutput.maxPhotoQualityPrioritization = .quality
        if photoOutput.isResponsiveCaptureSupported { photoOutput.isResponsiveCaptureEnabled = true }
        if let dimensions = camera.activeFormat.supportedMaxPhotoDimensions.max(by: {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }) {
            photoOutput.maxPhotoDimensions = dimensions
        }
        device = camera
        currentLens = .wide
        describe(camera)
        state.zoom = 1
        state.activeLens = state.lensStops.first { $0.lens == .wide && $0.zoomFactor == 1 }
        configured = true
    }

    private func denyAccess() {
        state.phase = .denied
        state.message = "允许相机访问后，即可取景和调节光圈。"
        publish()
    }

    func stopMetering() {
        timer?.cancel()
        timer = nil
    }

    private func startMetering() {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(250))
        source.setEventHandler { [weak self] in self?.readExposure() }
        timer = source
        source.resume()
    }

    func readExposure() {
        guard let device else { return }
        // Read back actual hardware values, rather than echoing requested values.
        state.aperture = device.lensAperture
        state.iso = device.iso
        state.exposureSeconds = device.exposureDuration.seconds
        state.exposureBias = device.exposureTargetBias
        state.zoom = Float(baseZoom(of: currentLens) * Double(device.videoZoomFactor))
        publish()
    }

    func publish() { onEvent?(.state(state)) }

    private func watchSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                                             object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.needsExposureReset = self.needsExposureReset || self.state.isApplying
                self.exposureRevision += 1
                self.state.isApplying = false
                self.state.phase = .interrupted
                self.state.message = "相机被系统暂时占用，恢复后可继续拍摄。"
                self.publish()
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                             object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.startAuthorized() }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                             object: session, queue: nil) { [weak self] note in
            guard let self else { return }
            let description = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription
                ?? "相机暂时不可用，请重试。"
            self.queue.async {
                self.needsExposureReset = true
                self.exposureRevision += 1
                self.state.phase = .unavailable
                self.state.message = description
                self.state.isApplying = false
                self.state.isCapturing = false
                self.publish()
            }
        })
    }
}
