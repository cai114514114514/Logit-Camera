import CameraCore
import CoreImage
import UIKit

/// 滤镜缩略图：把一张小图按各个配方渲染（后台、低优先级）。
enum LookThumbnails {
    private static let context = CIContext(options: [.cacheIntermediates: false, .priorityRequestLow: true])

    /// 最新取景帧缩到长边 136 的 3:4 小图。
    static func source(from frames: FrameGrabber) -> CIImage? {
        guard let (buffer, _) = frames.latestBuffer() else { return nil }
        return small(CIImage(cvPixelBuffer: buffer), longSide: 136)
    }

    static func source(from data: Data, longSide: CGFloat) -> CIImage? {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        return small(image, longSide: longSide)
    }

    static func small(_ image: CIImage, longSide: CGFloat) -> CIImage {
        let scale = longSide / max(image.extent.width, image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.minX, y: -scaled.extent.minY))
    }

    static func render(_ source: CIImage, _ recipe: LookRecipe) -> UIImage? {
        let graded = LookRenderer.apply(recipe, to: source, synchronous: true)
        guard let cg = context.createCGImage(graded, from: source.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
