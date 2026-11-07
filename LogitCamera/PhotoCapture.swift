@preconcurrency import AVFoundation
import ImageIO
import CameraCore

final class PhotoCapture: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private var result: Result<CapturedPhoto, Error> = .failure(CameraFailure.capture)
    private let completion: @Sendable (Result<CapturedPhoto, Error>) -> Void
    private let ratio: FrameRatio
    private let crop: CameraCore.NormalizedRect?

    init(ratio: FrameRatio, crop: CameraCore.NormalizedRect? = nil,
         completion: @escaping @Sendable (Result<CapturedPhoto, Error>) -> Void) {
        self.ratio = ratio
        self.crop = crop
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error { result = .failure(error); return }
        guard let original = photo.fileDataRepresentation() else { return }
        let data: Data
        do { data = try PhotoFraming.crop(original, to: ratio, rect: crop) }
        catch { result = .failure(error); return }
        // EXIF belongs to the captured photo; the live device may have moved on.
        let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let iso = (exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue
        result = .success(CapturedPhoto(
            data: data,
            aperture: (exif?[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue,
            iso: iso,
            exposureSeconds: (exif?[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue
        ))
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        completion(error.map { .failure($0) } ?? result)
    }
}

/// 一组连拍的结果收集（只在相机队列上访问）。
final class BurstCollector {
    var photos: [CapturedPhoto?]
    var remaining: Int

    init(count: Int) {
        photos = Array(repeating: nil, count: count)
        remaining = count
    }
}

extension CaptureSession {
    /// - Parameters:
    ///   - crop: AI 方案的裁切框（拍摄瞬间冻结）；为空时按画幅居中裁切。
    ///   - ratio: 与裁切框一起冻结的画幅；为空时用当前画幅。
    func capture(crop: CameraCore.NormalizedRect? = nil, ratio: FrameRatio? = nil) {
        queue.async {
            guard self.state.canCapture else {
                self.onEvent?(.captureRejected)
                return
            }
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            // 手动参数只有 speed 才会被照片采用；balanced 在弱光下会为多帧合成改写曝光。
            settings.photoQualityPrioritization = self.state.hasManualExposure ? .speed : .balanced
            self.alignPhotoConnection()
            let identifier = settings.uniqueID
            let processor = PhotoCapture(ratio: ratio ?? self.state.ratio, crop: crop) { [weak self = self] result in
                guard let self else { return }
                self.queue.async {
                    self.processors[identifier] = nil
                    self.state.isCapturing = false
                    self.publish()
                    switch result {
                    case .success(let photo): self.onEvent?(.photo(photo))
                    case .failure(let error): self.onEvent?(.captureFailed(error.localizedDescription))
                    }
                }
            }
            self.processors[identifier] = processor
            self.state.isCapturing = true
            self.publish()
            self.photoOutput.capturePhoto(with: settings, delegate: processor)
        }
    }

    /// AI 开启时的连拍：背靠背发出 `count` 次拍摄（约 0.4 秒拍完 6 张），全部完成后发出 `.burst`。
    /// 期间 `isBursting` 为真：不能再次拍摄，AI 也不写硬件。
    func captureBurst(count: Int, crop: CameraCore.NormalizedRect?, ratio: FrameRatio) {
        queue.async {
            guard self.state.canCapture, count > 0 else {
                self.onEvent?(.captureRejected)
                return
            }
            let burstID = UUID()
            let collector = BurstCollector(count: count)
            self.bursts[burstID] = collector
            self.state.isCapturing = true
            self.state.isBursting = true
            self.publish()
            self.alignPhotoConnection()
            for index in 0..<count {
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                settings.maxPhotoDimensions = self.burstDimensions ?? self.photoOutput.maxPhotoDimensions
                settings.photoQualityPrioritization = .speed
                let identifier = settings.uniqueID
                let processor = PhotoCapture(ratio: ratio, crop: crop) { [weak self = self] result in
                    guard let self else { return }
                    self.queue.async {
                        self.processors[identifier] = nil
                        guard let collector = self.bursts[burstID] else { return }
                        if case .success(let photo) = result { collector.photos[index] = photo }
                        collector.remaining -= 1
                        guard collector.remaining == 0 else { return }
                        self.bursts[burstID] = nil
                        self.state.isCapturing = false
                        self.state.isBursting = false
                        self.publish()
                        let photos = collector.photos.compactMap { $0 }
                        if photos.isEmpty {
                            self.onEvent?(.captureFailed(CameraFailure.capture.localizedDescription))
                        } else {
                            self.onEvent?(.burst(photos))
                        }
                    }
                }
                self.processors[identifier] = processor
                self.photoOutput.capturePhoto(with: settings, delegate: processor)
            }
        }
    }

    private func alignPhotoConnection() {
        if let connection = photoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }
}
