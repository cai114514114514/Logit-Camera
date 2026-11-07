@preconcurrency import AVFoundation
import CoreImage
import ImageIO
import CameraCore

struct CameraFrame: Sendable {
    let jpeg: Data
    let timestamp: TimeInterval
    let signature: [UInt8]

    func difference(from other: CameraFrame) -> Double {
        MeasurementMath.sceneChange(signature, other.signature)
    }
}

/// The delegate retains only the newest buffer. Compression happens on demand,
/// never once per camera frame and never on the main thread.
final class FrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var timestamp: TimeInterval = 0
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var frameHandler: (@Sendable (CVPixelBuffer) -> Void)?

    /// 每一帧的回调（在帧队列上调用），实时取景用它渲染。
    var onFrame: (@Sendable (CVPixelBuffer) -> Void)? {
        get { lock.withLock { frameHandler } }
        set { lock.withLock { frameHandler = newValue } }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        buffer = image
        timestamp = ProcessInfo.processInfo.systemUptime
        let handler = frameHandler
        lock.unlock()
        handler?(image)
    }

    /// 最新的取景缓冲及其时间（感知层使用）。超过 2 秒的旧帧视为无效。
    func latestBuffer() -> (CVPixelBuffer, TimeInterval)? {
        lock.lock()
        defer { lock.unlock() }
        guard let buffer, ProcessInfo.processInfo.systemUptime - timestamp < 2 else { return nil }
        return (buffer, timestamp)
    }

    func snapshot(maxDimension: CGFloat = 768) throws -> CameraFrame {
        lock.lock()
        let current = buffer
        let capturedAt = timestamp
        lock.unlock()
        guard let current, ProcessInfo.processInfo.systemUptime - capturedAt < 2 else {
            throw AIError.message("等待新的取景画面。")
        }
        let image = CIImage(cvPixelBuffer: current)
        let scale = min(1, maxDimension / max(image.extent.width, image.extent.height))
        let reduced = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let jpeg = context.jpegRepresentation(
            of: reduced, colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.65]
        ) else { throw AIError.message("无法读取取景图。") }
        let tiny = image.transformed(by: CGAffineTransform(scaleX: 16 / image.extent.width,
                                                         y: 16 / image.extent.height))
        var pixels = [UInt8](repeating: 0, count: 256)
        context.render(tiny, toBitmap: &pixels, rowBytes: 16,
                       bounds: CGRect(x: 0, y: 0, width: 16, height: 16),
                       format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        return CameraFrame(jpeg: jpeg, timestamp: capturedAt, signature: pixels)
    }
}
