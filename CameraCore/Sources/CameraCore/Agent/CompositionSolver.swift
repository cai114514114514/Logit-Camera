import Foundation

public struct CompositionTarget: Sendable, Equatable {
    public let crop: NormalizedRect
    /// 主体中心与目标锚点的距离（以裁切框为单位）。无主体时为 0。
    public let placementError: Double
}

/// 由主体位置与方案构图计算裁切框。纯函数；坐标为直立全画幅归一化坐标。
public enum CompositionSolver {
    /// - Parameter sensorAspect: 传感器像素宽高比（竖屏主摄为 0.75）。
    public static func solve(subject: NormalizedRect?, composition: Composition,
                             sensorAspect: Double, salientCenter: NormalizedPoint?) -> CompositionTarget {
        let ratio = composition.ratio.widthToHeight
        // 归一化宽度 = 归一化高度 × 比例 / 传感器宽高比。
        let widthPerHeight = ratio / sensorAspect
        let maxHeight = min(1, 1 / widthPerHeight)
        let minHeight = min(maxHeight, (composition.minCropArea / widthPerHeight).squareRoot())

        let desired = subject.map { $0.height / max(composition.subjectSize.midpoint, 0.05) } ?? maxHeight
        let height = min(max(desired, minHeight), maxHeight)
        let width = height * widthPerHeight

        let reference = subject?.center ?? salientCenter ?? NormalizedPoint(x: 0.5, y: 0.5)
        let crop = NormalizedRect(x: reference.x - composition.anchor.x * width,
                                  y: reference.y - composition.anchor.y * height,
                                  width: width, height: height).clamped()

        guard let subject else { return CompositionTarget(crop: crop, placementError: 0) }
        let dx = (subject.center.x - crop.x) / crop.width - composition.anchor.x
        let dy = (subject.center.y - crop.y) / crop.height - composition.anchor.y
        return CompositionTarget(crop: crop, placementError: (dx * dx + dy * dy).squareRoot())
    }
}

/// 裁切框的临界阻尼弹簧：各分量独立、精确积分、从静止出发不会过冲；结果始终在传感器内。
public struct CropSpring: Sendable {
    private let omega: Double
    private var position: [Double] = [0, 0, 1, 1]
    private var velocity: [Double] = [0, 0, 0, 0]

    public init(timeConstant: Double = 0.35) {
        omega = 1 / max(timeConstant, 0.01)
    }

    public mutating func reset(to rect: NormalizedRect) {
        position = [rect.x, rect.y, rect.width, rect.height]
        velocity = [0, 0, 0, 0]
    }

    public mutating func step(toward rect: NormalizedRect, dt: Double) -> NormalizedRect {
        let target = [rect.x, rect.y, rect.width, rect.height]
        let decay = exp(-omega * dt)
        for i in 0..<4 {
            let offset = position[i] - target[i]
            let carry = velocity[i] + omega * offset
            position[i] = target[i] + (offset + carry * dt) * decay
            velocity[i] = (velocity[i] - omega * carry * dt) * decay
        }
        let result = NormalizedRect(x: position[0], y: position[1], width: position[2], height: position[3]).clamped()
        position = [result.x, result.y, result.width, result.height]
        return result
    }
}
