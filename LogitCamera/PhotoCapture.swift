@preconcurrency import AVFoundation
import ImageIO
import CameraCore

final class PhotoCapture: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private var result: Result<CapturedPhoto, Error> = .failure(CameraFailure.capture)
    private let completion: @Sendable (Result<CapturedPhoto, Error>) -> Void
    private let ratio: FrameRatio

    init(ratio: FrameRatio, completion: @escaping @Sendable (Result<CapturedPhoto, Error>) -> Void) {
        self.ratio = ratio
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error { result = .failure(error); return }
        guard let original = photo.fileDataRepresentation() else { return }
        let data: Data
        do { data = try PhotoFraming.crop(original, to: ratio) }
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

extension CaptureSession {
    func capture() {
        queue.async {
            guard self.state.canCapture else {
                self.onEvent?(.captureRejected)
                return
            }
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            // Preserve requested manual settings. Balanced capture can override
            // exposure settings for multi-frame processing in low light.
            settings.photoQualityPrioritization = self.state.hasManualExposure ? .speed : .balanced
            if let connection = self.photoOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            let identifier = settings.uniqueID
            let processor = PhotoCapture(ratio: self.state.ratio) { [weak self = self] result in
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
}
