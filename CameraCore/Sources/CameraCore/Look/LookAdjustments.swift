import Foundation

/// 用户在预设之上的微调（规格 §3）。全部为 0 时不改变配方。
public struct LookAdjustments: Codable, Sendable, Equatable {
    public var exposure = 0.0       // −1…1 → ±1 EV
    public var temperature = 0.0    // −1…1
    public var tint = 0.0           // −1…1
    public var contrast = 0.0       // −1…1
    public var highlights = 0.0     // −1…0
    public var shadows = 0.0        // −1…1
    public var saturation = 0.0     // −1…1
    public var vibrance = 0.0       // −1…1
    public var fade = 0.0           // 0…1
    public var grain = 0.0          // 0…1
    public var vignette = 0.0       // −1…1

    public init() {}

    public static let zero = LookAdjustments()
    public var isZero: Bool { self == .zero }

    /// 把非零项追加到配方：曝光、白平衡、高光阴影进修正层末尾，其余进风格层末尾。
    public func apply(to recipe: LookRecipe) -> LookRecipe {
        var result = recipe
        func nonzero(_ v: Double) -> Bool { abs(v) > 1e-4 }
        if nonzero(exposure) { result.correction.append(.exposure(ev: exposure)) }
        if nonzero(temperature) || nonzero(tint) { result.correction.append(.whiteBalance(temperature: temperature, tint: tint)) }
        if nonzero(highlights) || nonzero(shadows) {
            result.correction.append(.highlightsShadows(highlights: min(0, highlights), shadows: shadows))
        }
        if nonzero(contrast) { result.style.append(.contrast(contrast)) }
        if nonzero(saturation) { result.style.append(.saturation(saturation)) }
        if nonzero(vibrance) { result.style.append(.vibrance(vibrance)) }
        if nonzero(fade) { result.style.append(.fade(fade)) }
        if nonzero(grain) { result.style.append(.grain(amount: grain, size: 0.5)) }
        if nonzero(vignette) { result.style.append(.vignette(amount: vignette, midpoint: 0.5)) }
        // 每层最多 16 个操作：超出的旧操作从前面丢弃（调整总是追加在末尾）。
        if result.correction.count > LookRecipe.maxOpsPerLayer { result.correction.removeFirst(result.correction.count - LookRecipe.maxOpsPerLayer) }
        if result.style.count > LookRecipe.maxOpsPerLayer { result.style.removeFirst(result.style.count - LookRecipe.maxOpsPerLayer) }
        return result
    }
}
