import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CameraCore

@Test func normalizedResetsTopLevelAndTIFFOrientationAndDimensions() {
    let input: [String: Any] = [
        kCGImagePropertyOrientation as String: 6,
        kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFOrientation as String: 6],
        kCGImagePropertyExifDictionary as String: [String: Any]()
    ]
    let output = PhotoMetadata.normalized(input, width: 300, height: 400)
    let tiff = output[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
    let exif = output[kCGImagePropertyExifDictionary as String] as? [String: Any]
    #expect(output[kCGImagePropertyOrientation as String] as? Int == 1)
    #expect(tiff?[kCGImagePropertyTIFFOrientation as String] as? Int == 1)
    #expect(output[kCGImagePropertyPixelWidth as String] as? Int == 300)
    #expect(output[kCGImagePropertyPixelHeight as String] as? Int == 400)
    #expect(exif?[kCGImagePropertyExifPixelXDimension as String] as? Int == 300)
    #expect(exif?[kCGImagePropertyExifPixelYDimension as String] as? Int == 400)
}

@Test func pixelSizeReadsTheOriginalDimensions() throws {
    let data = try makeJPEG(width: 1200, height: 1600)
    #expect(PhotoMetadata.pixelSize(of: data) == CGSize(width: 1200, height: 1600))
}

@Test func downsampleLimitsTheLongestEdge() throws {
    let data = try makeJPEG(width: 1200, height: 1600)
    let image = try #require(PhotoMetadata.downsample(data, maxPixel: 600))
    #expect(max(image.width, image.height) == 600)
}

@Test func unreadableDataHasNoSizeOrPreview() {
    #expect(PhotoMetadata.pixelSize(of: Data([1, 2, 3])) == nil)
    #expect(PhotoMetadata.downsample(Data([1, 2, 3]), maxPixel: 600) == nil)
}

private func makeJPEG(width: Int, height: Int) throws -> Data {
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let output = NSMutableData()
    let writer = try #require(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(writer, image, nil)
    #expect(CGImageDestinationFinalize(writer))
    return output as Data
}
