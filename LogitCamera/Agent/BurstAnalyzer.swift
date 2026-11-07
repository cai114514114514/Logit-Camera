import CameraCore
import CoreGraphics
import Foundation
import Vision

/// 连拍选片的本机分析（规格 §6.2）：每张缩到长边 1024，测清晰度、睁眼、人脸质量与系统美学分。
/// 拿不到的指标记为缺失，由 BurstSelector 忽略。
enum BurstAnalyzer {
    static func quality(of data: Data) async -> FrameQuality {
        guard let image = PhotoMetadata.downsample(data, maxPixel: 1024) else { return FrameQuality() }
        var quality = FrameQuality()
        var faceBox: CameraCore.NormalizedRect?
        if let faces = try? await DetectFaceLandmarksRequest().perform(on: image, orientation: .up), !faces.isEmpty {
            let size = CGSize(width: image.width, height: image.height)
            let largest = faces.max { $0.boundingBox.cgRect.width * $0.boundingBox.cgRect.height
                < $1.boundingBox.cgRect.width * $1.boundingBox.cgRect.height }
            if let largest {
                let r = largest.boundingBox.cgRect
                faceBox = CameraCore.NormalizedRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
                quality.eyesOpen = largest.landmarks.flatMap { marks -> Double? in
                    let left = MeasurementMath.eyeOpenness(eye: marks.leftEye.pointsInImageCoordinates(size).map {
                        CameraCore.NormalizedPoint(x: $0.x, y: $0.y) })
                    let right = MeasurementMath.eyeOpenness(eye: marks.rightEye.pointsInImageCoordinates(size).map {
                        CameraCore.NormalizedPoint(x: $0.x, y: $0.y) })
                    return [left, right].compactMap { $0 }.min()
                }
                var request = DetectFaceCaptureQualityRequest()
                request.inputFaceObservations = [largest]
                quality.faceQuality = (try? await request.perform(on: image, orientation: .up))?.first?
                    .captureQuality.map { Double($0.score) }
            }
        }
        if let luma = luma(image) {
            quality.sharpness = MeasurementMath.sharpness(luma, region: faceBox)
        }
        if let scores = try? await CalculateImageAestheticsScoresRequest().perform(on: image, orientation: .up) {
            quality.aesthetics = Double(scores.overallScore)
        }
        return quality
    }

    /// 灰度化并缩到长边约 320，供清晰度计算。
    private static func luma(_ image: CGImage) -> LumaImage? {
        let scale = min(1, 320 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        var bytes = [UInt8](repeating: 0, count: width * height)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? LumaImage(width: width, height: height, bytes: bytes) : nil
    }
}
