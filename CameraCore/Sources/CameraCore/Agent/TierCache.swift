import Foundation

/// 感知层中、慢档结果的缓存（修复审查 C1）：带时间戳与 epoch。
/// 超过 `maxAge` 的结果视为不存在；epoch 变化（停止、换主体类型）之前发起的写入被丢弃。
public struct TierCache<Value: Sendable>: Sendable {
    public static var defaultMaxAge: TimeInterval { 0.5 }

    private var value: Value?
    private var storedAt: TimeInterval = 0
    private var storedEpoch = 0

    public init() {}

    /// `epoch` 为发起这次检测时的 epoch；与 `current` 不同说明期间发生了停止或重置，丢弃。
    public mutating func store(_ value: Value, at time: TimeInterval, epoch: Int, current: Int) {
        guard epoch == current else { return }
        self.value = value
        storedAt = time
        storedEpoch = epoch
    }

    public func value(now: TimeInterval, epoch: Int, maxAge: TimeInterval = TierCache.defaultMaxAge) -> Value? {
        guard let value, storedEpoch == epoch, now - storedAt <= maxAge + 1e-9 else { return nil }
        return value
    }

    public mutating func clear() {
        value = nil
    }
}
