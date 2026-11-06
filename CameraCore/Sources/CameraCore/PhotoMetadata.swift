import CoreGraphics
import Foundation
import ImageIO

public enum PhotoMetadata {
    /// 裁切并校正方向后的元数据：顶层与 TIFF 方向都归一，尺寸与像素一致。
    public static func normalized(_ metadata: [String: Any], width: Int, height: Int) -> [String: Any] {
        var result = metadata
        result[kCGImagePropertyOrientation as String] = 1
        result[kCGImagePropertyPixelWidth as String] = width
        result[kCGImagePropertyPixelHeight as String] = height
        var tiff = result[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        result[kCGImagePropertyTIFFDictionary as String] = tiff
        var exif = result[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        exif[kCGImagePropertyExifPixelXDimension as String] = width
        exif[kCGImagePropertyExifPixelYDimension as String] = height
        result[kCGImagePropertyExifDictionary as String] = exif
        return result
    }

    /// 读取原图像素尺寸（已考虑 EXIF 方向），不解码像素。
    public static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int else { return nil }
        let orientation = properties[kCGImagePropertyOrientation as String] as? Int ?? 1
        return (5...8).contains(orientation)
            ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// 生成最长边不超过 `maxPixel` 的直立预览图，避免在主线程解码整张照片。
    public static func downsample(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
