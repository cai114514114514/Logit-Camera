import CameraCore
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum PhotoFraming {
    /// - Parameter rect: 直立全画幅归一化裁切框（左上原点）；为空时使用该画幅的最大居中框。
    static func crop(_ data: Data, to ratio: FrameRatio, rect: CameraCore.NormalizedRect? = nil) throws -> Data {
        if ratio == .standard && rect == nil { return data }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CameraFailure.capture }
        var metadata = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
        let orientation = (metadata[kCGImagePropertyOrientation as String] as? NSNumber)?.int32Value ?? 1
        let image = CIImage(cgImage: original).oriented(forExifOrientation: orientation)
        let width = Int(image.extent.width), height = Int(image.extent.height)
        let normalized = rect ?? CropGeometry.centered(ratio: ratio, sensorAspect: Double(width) / Double(height))
        let topLeft = CropGeometry.pixelRect(normalized, imageWidth: width, imageHeight: height, ratio: ratio)
        guard topLeft.width > 0, topLeft.height > 0 else { throw CameraFailure.capture }
        // Core Image 使用左下原点。
        let rect = CropGeometry.bottomLeft(topLeft, imageHeight: height)
            .offsetBy(dx: image.extent.minX, dy: image.extent.minY)
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let cropped = context.createCGImage(image.cropped(to: rect), from: rect,
                                                   format: .RGBA8, colorSpace: original.colorSpace ?? CGColorSpaceCreateDeviceRGB()) else {
            throw CameraFailure.capture
        }
        // Normalize orientation after cropping; preserve capture exposure metadata.
        metadata = PhotoMetadata.normalized(metadata, width: cropped.width, height: cropped.height)
        metadata[kCGImageDestinationLossyCompressionQuality as String] = 0.96
        let result = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(result, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CameraFailure.capture
        }
        CGImageDestinationAddImage(writer, cropped, metadata as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw CameraFailure.capture }
        return result as Data
    }
}
