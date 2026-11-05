/// 连续两次观察都满足条件，才允许应用开始拍摄倒计时。
public struct CaptureReadiness: Sendable {
    public private(set) var confirmations: Int = 0

    public init() {}

    public mutating func observe(confirmed: Bool, stable: Bool, hardwareReady: Bool) -> Bool {
        guard confirmed && stable && hardwareReady else {
            reset()
            return false
        }

        confirmations = min(confirmations + 1, 2)
        return confirmations >= 2
    }

    public mutating func reset() {
        confirmations = 0
    }
}
