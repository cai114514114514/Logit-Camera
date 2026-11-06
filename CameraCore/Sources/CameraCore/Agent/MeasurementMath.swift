import Foundation

/// 8 位灰度图（行优先，无填充）。感知层把取景帧的 Y 平面降采样成它。
public struct LumaImage: Sendable {
    public let width: Int
    public let height: Int
    public let bytes: [UInt8]

    public init(width: Int, height: Int, bytes: [UInt8]) {
        precondition(bytes.count == width * height, "LumaImage size mismatch")
        self.width = width
        self.height = height
        self.bytes = bytes
    }
}

/// 感知层中可单元测试的纯计算。
public enum MeasurementMath {
    public static let clipHighLevel: UInt8 = 250
    public static let clipLowLevel: UInt8 = 5

    public static func luminance(_ image: LumaImage, subject: NormalizedRect?) -> LuminanceStats {
        var bins = [Double](repeating: 0, count: 64)
        var high = 0, low = 0, sum = 0
        for value in image.bytes {
            bins[Int(value) >> 2] += 1
            sum += Int(value)
            if value >= clipHighLevel { high += 1 }
            if value <= clipLowLevel { low += 1 }
        }
        let count = Double(max(image.bytes.count, 1))
        return LuminanceStats(histogram: bins.map { $0 / count }, clipHigh: Double(high) / count,
                              clipLow: Double(low) / count, mean: Double(sum) / count / 255,
                              subjectMean: subject.flatMap { mean(image, in: $0) })
    }

    /// 3×3 拉普拉斯响应的方差，按亮度归一后映射到 0…1。
    public static func sharpness(_ image: LumaImage, region: NormalizedRect?) -> Double {
        let (x0, y0, x1, y1) = pixelBounds(image, region ?? .full)
        guard x1 - x0 >= 3, y1 - y0 >= 3 else { return 0 }
        var sum = 0.0, sumSquares = 0.0, luma = 0.0, n = 0.0
        let w = image.width
        image.bytes.withUnsafeBufferPointer { p in
            for y in (y0 + 1)..<(y1 - 1) {
                for x in (x0 + 1)..<(x1 - 1) {
                    let c = Double(p[y * w + x])
                    let lap = (Double(p[y * w + x - 1]) + Double(p[y * w + x + 1])
                               + Double(p[(y - 1) * w + x]) + Double(p[(y + 1) * w + x]) - 4 * c) / 255
                    sum += lap
                    sumSquares += lap * lap
                    luma += c / 255
                    n += 1
                }
            }
        }
        let variance = max(0, sumSquares / n - (sum / n) * (sum / n))
        let mean = luma / n
        let normalized = variance / (mean * mean + 0.01)
        return normalized / (normalized + 0.02)
    }

    /// 眼部轮廓的高宽比，0.3 及以上视为完全睁开。点数不足 4 个时返回 nil。
    public static func eyeOpenness(eye points: [NormalizedPoint]) -> Double? {
        guard points.count >= 4 else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        let width = (xs.max() ?? 0) - (xs.min() ?? 0)
        guard width > 0 else { return nil }
        let ratio = ((ys.max() ?? 0) - (ys.min() ?? 0)) / width
        return min(1, ratio / 0.3)
    }

    /// 16×16 区块平均亮度签名。
    public static func signature(_ image: LumaImage) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 256)
        for by in 0..<16 {
            for bx in 0..<16 {
                let rect = NormalizedRect(x: Double(bx) / 16, y: Double(by) / 16, width: 1.0 / 16, height: 1.0 / 16)
                result[by * 16 + bx] = UInt8(((mean(image, in: rect) ?? 0) * 255).rounded())
            }
        }
        return result
    }

    /// 去均值后的平均绝对差（0…1）：整体变亮变暗不算场景变化。
    public static func sceneChange(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        let count = Double(a.count)
        let meanA = a.reduce(0.0) { $0 + Double($1) } / count
        let meanB = b.reduce(0.0) { $0 + Double($1) } / count
        return zip(a, b).reduce(0.0) { $0 + abs((Double($1.0) - meanA) - (Double($1.1) - meanB)) } / count / 255
    }

    private static func mean(_ image: LumaImage, in rect: NormalizedRect) -> Double? {
        let (x0, y0, x1, y1) = pixelBounds(image, rect)
        guard x1 > x0, y1 > y0 else { return nil }
        var sum = 0
        for y in y0..<y1 { for x in x0..<x1 { sum += Int(image.bytes[y * image.width + x]) } }
        return Double(sum) / Double((x1 - x0) * (y1 - y0)) / 255
    }

    private static func pixelBounds(_ image: LumaImage, _ rect: NormalizedRect) -> (Int, Int, Int, Int) {
        let r = rect.clamped()
        let x0 = Int((r.x * Double(image.width)).rounded(.down))
        let y0 = Int((r.y * Double(image.height)).rounded(.down))
        let x1 = min(image.width, max(x0 + 1, Int(((r.x + r.width) * Double(image.width)).rounded(.up))))
        let y1 = min(image.height, max(y0 + 1, Int(((r.y + r.height) * Double(image.height)).rounded(.up))))
        return (x0, y0, x1, y1)
    }
}
