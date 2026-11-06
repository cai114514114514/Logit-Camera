import CameraCore
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum PhotoFraming {
    static func crop(_ data: Data, to ratio: FrameRatio) throws -> Data {
        if ratio == .standard { return data }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CameraFailure.capture }
        var metadata = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
        let orientation = (metadata[kCGImagePropertyOrientation as String] as? NSNumber)?.int32Value ?? 1
        let image = CIImage(cgImage: original).oriented(forExifOrientation: orientation)
        guard let localRect = ratio.cropRect(width: Int(image.extent.width), height: Int(image.extent.height)) else {
            throw CameraFailure.capture
        }
        let rect = localRect.offsetBy(dx: image.extent.minX, dy: image.extent.minY)
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
