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
    /// 色度统计。`cb`、`cr`、`luma` 是同一网格（width × height）上的采样，0…255。
    public static func chroma(cb: [UInt8], cr: [UInt8], luma: [UInt8], width: Int, height: Int) -> ChromaStats {
        let count = min(cb.count, cr.count, luma.count, width * height)
        guard count > 0, width > 0, height > 0 else { return ChromaStats(cb: 0, cr: 0, saturation: 0, topLuma: 0, topCb: 0) }
        var sumCb = 0.0, sumCr = 0.0, mid = 0.0, sat = 0.0
        var topLuma = 0.0, topCb = 0.0, top = 0.0
        let topRows = max(1, Int(Double(height) * 0.3))
        for i in 0..<count {
            let y = Double(luma[i]) / 255
            let b = (Double(cb[i]) - 128) / 255, r = (Double(cr[i]) - 128) / 255
            sat += (b * b + r * r).squareRoot()
            if y > 0.2 && y < 0.8 {
                sumCb += b
                sumCr += r
                mid += 1
            }
            if i / width < topRows {
                topLuma += y
                topCb += b
                top += 1
            }
        }
        return ChromaStats(cb: mid > 0 ? sumCb / mid : 0, cr: mid > 0 ? sumCr / mid : 0, saturation: sat / Double(count),
                           topLuma: top > 0 ? topLuma / top : 0, topCb: top > 0 ? topCb / top : 0)
    }

    public static let clipHighLevel: UInt8 = 250
    public static let clipLowLevel: UInt8 = 5

    public static func luminance(_ image: LumaImage, subject: NormalizedRect?) -> LuminanceStats {
        var bins = [Int](repeating: 0, count: 64)
        var high = 0, low = 0, sum = 0
        let count = image.bytes.count
        image.bytes.withUnsafeBufferPointer { buffer in
            guard let p = buffer.baseAddress else { return }
            bins.withUnsafeMutableBufferPointer { b in
                guard let bp = b.baseAddress else { return }
                for i in 0..<count {
                    let value = Int(p[i])
                    bp[value >> 2] += 1
                    sum += value
                    if value >= Int(clipHighLevel) { high += 1 }
                    if value <= Int(clipLowLevel) { low += 1 }
                }
            }
        }
        let total = Double(max(count, 1))
        return LuminanceStats(histogram: bins.map { Double($0) / total }, clipHigh: Double(high) / total,
                              clipLow: Double(low) / total, mean: Double(sum) / total / 255,
                              subjectMean: subject.flatMap { mean(image, in: $0) })
    }

    /// 3×3 拉普拉斯响应的方差，按亮度归一后映射到 0…1。
    public static func sharpness(_ image: LumaImage, region: NormalizedRect?) -> Double {
        let (x0, y0, x1, y1) = pixelBounds(image, region ?? .full)
        guard x1 - x0 >= 3, y1 - y0 >= 3 else { return 0 }
        var sum = 0, sumSquares = 0, luma = 0, n = 0
        let w = image.width
        image.bytes.withUnsafeBufferPointer { buffer in
            guard let p = buffer.baseAddress else { return }
            for y in (y0 + 1)..<(y1 - 1) {
                let row = y * w
                for x in (x0 + 1)..<(x1 - 1) {
                    let c = Int(p[row + x])
                    let lap = Int(p[row + x - 1]) + Int(p[row + x + 1]) + Int(p[row - w + x]) + Int(p[row + w + x]) - 4 * c
                    sum += lap
                    sumSquares += lap * lap
                    luma += c
                    n += 1
                }
            }
        }
        let count = Double(n)
        let meanLap = Double(sum) / count / 255
        let variance = max(0, Double(sumSquares) / count / (255 * 255) - meanLap * meanLap)
        let mean = Double(luma) / count / 255
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

    /// 16×16 区块平均亮度签名（单次遍历）。
    public static func signature(_ image: LumaImage) -> [UInt8] {
        var sums = [Int](repeating: 0, count: 256)
        var counts = [Int](repeating: 0, count: 256)
        let w = image.width, h = image.height
        image.bytes.withUnsafeBufferPointer { buffer in
            guard let p = buffer.baseAddress else { return }
            for y in 0..<h {
                let block = (y * 16 / h) * 16
                let row = y * w
                for x in 0..<w {
                    let index = block + x * 16 / w
                    sums[index] += Int(p[row + x])
                    counts[index] += 1
                }
            }
        }
        return (0..<256).map { counts[$0] > 0 ? UInt8((Double(sums[$0]) / Double(counts[$0])).rounded()) : 0 }
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
        image.bytes.withUnsafeBufferPointer { buffer in
            guard let p = buffer.baseAddress else { return }
            for y in y0..<y1 {
                let row = y * image.width
                for x in x0..<x1 { sum += Int(p[row + x]) }
            }
        }
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
