/// 主摄数字变焦的可选档位。只列出设备当前格式真正支持的倍率。
public enum ZoomStops {
    public static func available(min: Double, max: Double, candidates: [Double] = [1, 2, 3]) -> [Double] {
        candidates.filter { $0 >= min - 0.01 && $0 <= max + 0.01 }
    }

    public static func clamp(_ zoom: Double, min: Double, max: Double) -> Double {
        guard zoom.isFinite else { return min }
        return Swift.min(max, Swift.max(min, zoom))
    }
}
