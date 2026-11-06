import Foundation
import CoreGraphics

public enum FrameRatio: String, CaseIterable, Codable, Sendable, Identifiable {
    case standard = "3:4"
    case tall = "9:16"
    case square = "1:1"

    public var id: String { rawValue }

    public var widthToHeight: Double {
        Double(components.width) / Double(components.height)
    }

    /// 返回居中且对齐像素的裁切范围，预览与照片共用同一种比例。
    public func cropRect(width: Int, height: Int) -> CGRect? {
        guard width > 0, height > 0 else { return nil }

        let units = components
        let scale = min(width / units.width, height / units.height)
        let cropWidth: Int
        let cropHeight: Int

        if scale > 0 {
            // 使用比例的整数倍，避免奇数尺寸经过取整后改变画幅比例。
            cropWidth = units.width * scale
            cropHeight = units.height * scale
        } else if Double(width) / Double(height) > widthToHeight {
            // 极小图像无法容纳一个完整比例单位，优先保证至少保留一个像素。
            cropWidth = max(1, Int((Double(height) * widthToHeight).rounded(.down)))
            cropHeight = height
        } else {
            cropWidth = width
            cropHeight = max(1, Int((Double(width) / widthToHeight).rounded(.down)))
        }

        let originX = (width - cropWidth) / 2
        let originY = (height - cropHeight) / 2
        return CGRect(
            x: CGFloat(originX), y: CGFloat(originY),
            width: CGFloat(cropWidth), height: CGFloat(cropHeight)
        )
    }

    var components: (width: Int, height: Int) {
        switch self {
        case .standard: (3, 4)
        case .tall: (9, 16)
        case .square: (1, 1)
        }
    }
}
