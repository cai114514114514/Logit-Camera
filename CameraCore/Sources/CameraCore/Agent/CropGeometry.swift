import CoreGraphics

/// 把归一化裁切框换算成照片像素矩形：严格保持画幅比例（比例单位的整数倍），并夹在图内。
public enum CropGeometry {
    /// - Returns: 左上原点的像素矩形（直立图像坐标）。
    public static func pixelRect(_ crop: NormalizedRect, imageWidth: Int, imageHeight: Int, ratio: FrameRatio) -> CGRect {
        let units = ratio.components
        let targetWidth = crop.width * Double(imageWidth), targetHeight = crop.height * Double(imageHeight)
        let scale = Int(min(targetWidth / Double(units.width), targetHeight / Double(units.height)).rounded(.down))
        guard scale > 0 else { return ratio.cropRect(width: imageWidth, height: imageHeight) ?? .zero }
        let width = min(units.width * scale, imageWidth), height = min(units.height * scale, imageHeight)
        let centerX = crop.center.x * Double(imageWidth), centerY = crop.center.y * Double(imageHeight)
        let x = min(max(Int((centerX - Double(width) / 2).rounded()), 0), imageWidth - width)
        let y = min(max(Int((centerY - Double(height) / 2).rounded()), 0), imageHeight - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// 换成 Core Image 的左下原点坐标。
    public static func bottomLeft(_ rect: CGRect, imageHeight: Int) -> CGRect {
        CGRect(x: rect.minX, y: CGFloat(imageHeight) - rect.maxY, width: rect.width, height: rect.height)
    }

    /// 某画幅在传感器中的最大居中裁切框（归一化）。
    public static func centered(ratio: FrameRatio, sensorAspect: Double) -> NormalizedRect {
        let widthPerHeight = ratio.widthToHeight / sensorAspect
        let height = min(1, 1 / widthPerHeight), width = height * widthPerHeight
        return NormalizedRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }
}
