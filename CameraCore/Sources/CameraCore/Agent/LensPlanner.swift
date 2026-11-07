import Foundation

/// 一个物理镜头档。`zoomFactor` 为显示倍率（0.5、1、2、4…）。
public struct LensStop: Codable, Sendable, Equatable, Hashable {
    public enum Lens: String, Codable, Sendable { case ultraWide, wide, telephoto }

    /// 等效焦距（mm）。
    public var focalLength: Double
    public var zoomFactor: Double
    public var lens: Lens

    public init(focalLength: Double, zoomFactor: Double, lens: Lens) {
        self.focalLength = focalLength
        self.zoomFactor = zoomFactor
        self.lens = lens
    }

    public var isMain: Bool { lens == .wide }

    /// 主摄等效焦距。
    public static let mainFocalLength = 24.0

    /// 由虚拟三摄的 switch-over 倍率与显示倍率换算出镜头档。
    /// - Parameters:
    ///   - switchOver: 虚拟设备的 switch-over 倍率，例如 [2, 8]（超广角→主摄、主摄→长焦）。
    ///   - displayMultiplier: `displayVideoZoomFactorMultiplier`，例如 0.5。
    public static func stops(switchOver: [Double], displayMultiplier: Double,
                             hasUltraWide: Bool, hasTele: Bool) -> [LensStop] {
        let main = mainFocalLength
        var result: [LensStop] = []
        let mainDisplay = hasUltraWide && !switchOver.isEmpty ? switchOver[0] * displayMultiplier : 1
        if hasUltraWide, mainDisplay > 0 {
            let zoom = displayMultiplier / mainDisplay
            // 0.5× 超广角的标称等效焦距是 13 mm（按倍率换算为 12）。
            let focal = abs(zoom - 0.5) < 0.01 ? 13 : (main * zoom).rounded()
            result.append(LensStop(focalLength: focal, zoomFactor: zoom, lens: .ultraWide))
        }
        result.append(LensStop(focalLength: main, zoomFactor: 1, lens: .wide))
        result.append(LensStop(focalLength: main * 2, zoomFactor: 2, lens: .wide))
        let teleIndex = hasUltraWide ? 1 : 0
        if hasTele, switchOver.count > teleIndex, mainDisplay > 0 {
            let display = switchOver[teleIndex] * displayMultiplier / mainDisplay
            if display > 2.05 {
                result.append(LensStop(focalLength: (main * display).rounded(), zoomFactor: display, lens: .telephoto))
            }
        }
        return result
    }
}

/// 焦段选择（规格 §5.1）：意图焦距吸附到最近的镜头档；同一方案不重复切换；非主摄弱光时回退主摄。
public struct LensPlanner: Sendable {
    public static let starvationHold: TimeInterval = 1

    public let stops: [LensStop]
    public private(set) var current: LensStop?
    private var planID: UUID?
    private var fellBack = false
    private var starvedSince: TimeInterval?

    public init(stops: [LensStop]) {
        self.stops = stops
    }

    public mutating func reset() {
        current = nil
        planID = nil
        fellBack = false
        starvedSince = nil
    }

    /// 对数距离最近的档。
    public static func nearest(_ focal: Double, in stops: [LensStop]) -> LensStop? {
        guard focal > 0 else { return nil }
        return stops.min { abs(log($0.focalLength / focal)) < abs(log($1.focalLength / focal)) }
    }

    /// 新方案到达时调用；返回需要切换到的档，nil 表示不切换。
    public mutating func plan(for intent: LensIntent, genreDefault: Double, planID: UUID) -> LensStop? {
        guard planID != self.planID else { return nil }
        self.planID = planID
        fellBack = false
        starvedSince = nil
        let focal = intent.focalLength > 0 ? intent.focalLength : genreDefault
        guard let stop = Self.nearest(focal, in: stops) ?? stops.first(where: \.isMain), stop != current else { return nil }
        current = stop
        return stop
    }

    /// 每帧报告曝光程序是否 starved；在非主摄上持续 1 秒则回退主摄（本方案内不再切回）。
    public mutating func reportStarved(_ starved: Bool, now: TimeInterval) -> LensStop? {
        guard let current, !current.isMain, !fellBack else {
            starvedSince = nil
            return nil
        }
        guard starved else {
            starvedSince = nil
            return nil
        }
        let since = starvedSince ?? now
        starvedSince = since
        guard now - since >= Self.starvationHold - 1e-9,
              let main = stops.first(where: { $0.isMain && $0.zoomFactor == 1 }) else { return nil }
        fellBack = true
        starvedSince = nil
        self.current = main
        return main
    }
}
