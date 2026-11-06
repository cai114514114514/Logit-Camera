import CoreMotion
import Foundation

/// 手机角速度（rad/s），陀螺仪 60 Hz，0.3 秒指数滑动平均。
final class MotionMonitor: @unchecked Sendable {
    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var smoothed = 0.0

    var angularSpeed: Double { lock.withLock { smoothed } }

    func start() {
        guard manager.isGyroAvailable, !manager.isGyroActive else { return }
        manager.gyroUpdateInterval = 1.0 / 60
        manager.startGyroUpdates(to: queue) { [weak self] data, _ in
            guard let self, let rate = data?.rotationRate else { return }
            let speed = (rate.x * rate.x + rate.y * rate.y + rate.z * rate.z).squareRoot()
            // α = dt / (τ + dt)，τ = 0.3 s。
            let alpha = (1.0 / 60) / (0.3 + 1.0 / 60)
            self.lock.withLock { self.smoothed += alpha * (speed - self.smoothed) }
        }
    }

    func stop() {
        manager.stopGyroUpdates()
        lock.withLock { smoothed = 0 }
    }
}
