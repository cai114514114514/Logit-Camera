import CameraCore
import CoreVideo
import Foundation
import Vision

/// 跨并发域传递的取景缓冲。缓冲只读，由 FrameGrabber 持有最新一份。
struct FrameBuffer: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let timestamp: TimeInterval
    var width: Int { CVPixelBufferGetWidth(pixelBuffer) }
    var height: Int { CVPixelBufferGetHeight(pixelBuffer) }
}

/// Vision 检测（iOS 27 Swift API）。缓冲已是直立方向；Vision 的左下原点坐标在这里统一换成左上原点。
struct VisionDetectors: Sendable {
    func faces(_ frame: FrameBuffer) async throws -> [Subject] {
        let landmarks = try await DetectFaceLandmarksRequest().perform(on: frame.pixelBuffer, orientation: .up)
        guard !landmarks.isEmpty else { return [] }
        var quality = DetectFaceCaptureQualityRequest()
        quality.inputFaceObservations = landmarks
        let scored = (try? await quality.perform(on: frame.pixelBuffer, orientation: .up)) ?? []
        let size = CGSize(width: frame.width, height: frame.height)
        return landmarks.enumerated().map { index, face in
            let eyes = face.landmarks.flatMap { marks -> Double? in
                let left = MeasurementMath.eyeOpenness(eye: imagePoints(marks.leftEye, size))
                let right = MeasurementMath.eyeOpenness(eye: imagePoints(marks.rightEye, size))
                return [left, right].compactMap { $0 }.min()
            }
            let match = scored.count == landmarks.count ? scored[index] : scored.first { $0.uuid == face.uuid }
            let score = match?.captureQuality?.score
            return Subject(id: 100 + index, kind: .face, box: topLeft(face.boundingBox), confidence: Double(face.confidence),
                           yaw: face.yaw.converted(to: .degrees).value, pitch: face.pitch.converted(to: .degrees).value,
                           roll: face.roll.converted(to: .degrees).value, eyeOpenness: eyes, faceQuality: score.map(Double.init))
        }
    }

    func bodies(_ frame: FrameBuffer) async throws -> [Subject] {
        var request = DetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        return try await request.perform(on: frame.pixelBuffer, orientation: .up).enumerated().map { index, human in
            Subject(id: 200 + index, kind: .body, box: topLeft(human.boundingBox), confidence: Double(human.confidence))
        }
    }

    func horizon(_ frame: FrameBuffer) async throws -> Double? {
        try await DetectHorizonRequest().perform(on: frame.pixelBuffer, orientation: .up)?
            .angle.converted(to: .degrees).value
    }

    func saliency(_ frame: FrameBuffer) async throws -> CameraCore.NormalizedRect? {
        let observation = try await GenerateAttentionBasedSaliencyImageRequest().perform(on: frame.pixelBuffer, orientation: .up)
        // 取面积最大的显著区域；Vision 四角点为左下原点。
        return observation.salientObjects.map { object -> CameraCore.NormalizedRect in
            let xs = [object.topLeft, object.topRight, object.bottomLeft, object.bottomRight].map { Double($0.x) }
            let ys = [object.topLeft, object.topRight, object.bottomLeft, object.bottomRight].map { Double($0.y) }
            let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
            return CameraCore.NormalizedRect(x: xs.min() ?? 0, y: 1 - maxY, width: (xs.max() ?? 0) - (xs.min() ?? 0),
                                             height: maxY - minY)
        }.max { $0.area < $1.area }
    }

    func aesthetics(_ frame: FrameBuffer) async throws -> AestheticsHint {
        let scores = try await CalculateImageAestheticsScoresRequest().perform(on: frame.pixelBuffer, orientation: .up)
        let labels = (try? await ClassifyImageRequest().perform(on: frame.pixelBuffer, orientation: .up)) ?? []
        let top = labels.filter { $0.confidence > 0.1 }.sorted { $0.confidence > $1.confidence }.prefix(5).map(\.identifier)
        return AestheticsHint(score: Double(scores.overallScore), isUtility: scores.isUtility, labels: Array(top))
    }

    func topLeft(_ rect: Vision.NormalizedRect) -> CameraCore.NormalizedRect {
        let r = rect.cgRect
        return CameraCore.NormalizedRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }

    func visionRect(_ rect: CameraCore.NormalizedRect) -> Vision.NormalizedRect {
        Vision.NormalizedRect(x: rect.x, y: 1 - rect.y - rect.height, width: rect.width, height: rect.height)
    }

    private func imagePoints(_ region: FaceObservation.Landmarks2D.Region, _ size: CGSize) -> [CameraCore.NormalizedPoint] {
        region.pointsInImageCoordinates(size).map { CameraCore.NormalizedPoint(x: $0.x, y: $0.y) }
    }
}
