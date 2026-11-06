import CameraCore
import Foundation

/// 执行层：把当前方案落到相机上（对焦、曝光、构图），并逐帧判定拍摄条件。
/// 自身不做审美判断；所有硬件写入经 CaptureSession 在相机队列执行。
@MainActor
final class Executor {
    /// 竖屏主摄传感器的像素宽高比。
    static let sensorAspect = 0.75

    private let capture: CaptureSession
    private(set) var plan: ShotPlan?
    private var evaluator: TriggerEvaluator?
    private var exposure = ExposureController()
    private var spring = CropSpring()
    private var springReady = false
    private var lastFocus: CameraCore.NormalizedPoint?
    private var lastTime: TimeInterval?
    private(set) var crop: CameraCore.NormalizedRect = .full
    private(set) var placementError = 0.0

    init(capture: CaptureSession) {
        self.capture = capture
    }

    var exposureSettled: Bool { exposure.settled }

    func apply(_ newPlan: ShotPlan, isDefault: Bool) {
        let previous = plan
        plan = newPlan
        evaluator = TriggerEvaluator(plan: newPlan)
        exposure.reset()
        lastFocus = nil
        // 默认方案只做辅助，不改动用户当前的光圈。
        guard !isDefault, previous?.exposure.aperture != newPlan.exposure.aperture else { return }
        switch newPlan.exposure.aperture.mode {
        case .prefer: capture.setAperture(newPlan.exposure.aperture.value.map(Float.init))
        case .auto: capture.setAperture(nil)
        }
    }

    func ingest(_ m: SceneMeasurement, state: CameraState, now: TimeInterval) -> TriggerReport? {
        guard let plan, var evaluator else { return nil }
        let subject = plan.subject == .none ? nil : m.primarySubject?.box
        let salient = m.subjects.first { $0.kind == .salient }?.box.center
        let target = CompositionSolver.solve(subject: subject, composition: plan.composition,
                                             sensorAspect: Self.sensorAspect, salientCenter: salient)
        if springReady {
            let dt = min(max(now - (lastTime ?? now), 0), 0.5)
            crop = spring.step(toward: target.crop, dt: dt)
        } else {
            spring.reset(to: target.crop)
            crop = target.crop
            springReady = true
        }
        lastTime = now
        placementError = subject.map { placement(of: $0, in: crop, anchor: plan.composition.anchor) } ?? 0

        if let center = subject?.center, distance(center, lastFocus) > 0.05 {
            lastFocus = center
            capture.setSubjectPoint(center)
        }
        if state.canCapture {
            let reading = ExposureState(bias: Double(state.exposureBias), shutterSeconds: state.exposureSeconds ?? 0,
                                        shutterLocked: state.selectedShutter != nil, iso: Double(state.iso ?? 0),
                                        minISO: Double(state.minISO), minBias: Double(state.minimumBias),
                                        maxBias: Double(state.maximumBias))
            switch exposure.step(m, intent: plan.exposure, state: reading) {
            case .none: break
            case .setBias(let value): capture.setAgentBias(value)
            case .lockShutter(let seconds): capture.lockShutter(seconds)
            case .releaseShutter: capture.releaseShutter()
            }
        }
        let report = evaluator.update(m, now: now, placementError: placementError, exposureSettled: exposure.settled)
        self.evaluator = evaluator
        return report
    }

    /// AI 停止：释放快门锁，回到系统自动对焦与曝光节奏；保留用户可见的光圈与 EV。
    func stop(state: CameraState) {
        if state.selectedShutter != nil { capture.releaseShutter() }
        plan = nil
        evaluator = nil
        springReady = false
        crop = .full
        lastFocus = nil
        lastTime = nil
    }

    private func placement(of subject: CameraCore.NormalizedRect, in crop: CameraCore.NormalizedRect,
                           anchor: CameraCore.NormalizedPoint) -> Double {
        guard crop.width > 0, crop.height > 0 else { return 1 }
        let dx = (subject.center.x - crop.x) / crop.width - anchor.x
        let dy = (subject.center.y - crop.y) / crop.height - anchor.y
        return (dx * dx + dy * dy).squareRoot()
    }

    private func distance(_ a: CameraCore.NormalizedPoint, _ b: CameraCore.NormalizedPoint?) -> Double {
        guard let b else { return .infinity }
        return ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }
}
