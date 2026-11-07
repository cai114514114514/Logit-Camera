import CameraCore
import Foundation

/// 执行层：把意图落到相机上——镜头（LensPlanner）、全手动曝光（ExposureProgram）、
/// 对焦、裁切（CompositionSolver + CropSpring），并逐帧给时机打分（MomentScorer）。
/// 自身不做审美判断；所有硬件写入经 CaptureSession 在相机队列执行，连拍期间不写硬件。
@MainActor
final class Executor {
    /// 竖屏传感器的像素宽高比。
    static let sensorAspect = 0.75

    private let capture: CaptureSession
    private(set) var plan: ShotPlan?
    private var scorer: MomentScorer?
    private var exposure = ExposureProgram()
    private var lenses: LensPlanner?
    private var spring = CropSpring()
    private var springReady = false
    private var lastFocus: CameraCore.NormalizedPoint?
    private var lastTime: TimeInterval?
    private var lastZoom: Float?
    private(set) var crop: CameraCore.NormalizedRect = .full
    private(set) var placementError = 0.0
    private(set) var exposureSettled = false
    private(set) var lastExposure: ExposureDecision?

    init(capture: CaptureSession) {
        self.capture = capture
    }

    /// 当前选择的镜头档。
    var lens: LensStop? { lenses?.current }

    func apply(_ newPlan: ShotPlan, state: CameraState, now: TimeInterval) {
        plan = newPlan
        scorer = MomentScorer(plan: newPlan, startedAt: now)
        exposure.reset()
        exposureSettled = false
        lastFocus = nil
        if lenses?.stops != state.lensStops { lenses = LensPlanner(stops: state.lensStops) }
        let genreDefault = (try? Knowledge.playbook(newPlan.genre).defaultFocalLength) ?? LensStop.mainFocalLength
        if let stop = lenses?.plan(for: newPlan.lens, genreDefault: genreDefault, planID: newPlan.id) {
            capture.setLens(stop)
            springReady = false
        }
        capture.setRatio(newPlan.composition.ratio)
    }

    /// 新方案、冷却结束、再拍一张时重新计时耐心期。
    func restartMoment(at now: TimeInterval) {
        scorer?.restart(at: now)
    }

    func ingest(_ m: SceneMeasurement, state: CameraState, now: TimeInterval) -> MomentReport? {
        guard let plan, var scorer else { return nil }
        // 连拍期间冻结一切：曝光、对焦、裁切框都保持拍摄瞬间的状态。
        guard !state.isBursting else { return nil }
        if lastZoom != state.zoom {
            lastZoom = state.zoom
            springReady = false
        }
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

        let focusPoint = subject?.center ?? CameraCore.NormalizedPoint(x: 0.5, y: 0.5)
        if distance(focusPoint, lastFocus) > 0.05 {
            lastFocus = focusPoint
            capture.setSubjectPoint(focusPoint)
        }

        if state.phase == .ready, !state.isCapturing, !state.isApplying {
            let reading = ExposureReading(aperture: Double(state.aperture ?? 1.8),
                                          shutter: state.exposureSeconds ?? 1.0 / 60,
                                          iso: Double(state.iso ?? 100))
            let limits = ExposureLimits(minISO: Double(state.minISO), maxISO: Double(state.maxISO),
                                        minShutter: state.minShutter, maxShutter: state.maxShutter,
                                        apertureStops: state.apertureRange?.stops.map(Double.init) ?? [],
                                        variableAperture: state.supportsAperturePriority)
            let context = ExposureContext(focalLength: Double(state.zoom) * LensStop.mainFocalLength,
                                          deviceAngularSpeed: m.deviceAngularSpeed, subjectSpeed: m.subjectSpeed,
                                          isNight: plan.genre == .night)
            let decision = exposure.step(luminance: m.luminance, intent: plan.exposure, reading: reading,
                                         limits: limits, context: context, writePending: state.agentWritePending)
            lastExposure = decision
            exposureSettled = decision.settled
            if let target = decision.target { capture.setManualExposure(target) }
            if let stop = lenses?.reportStarved(decision.starved, now: now) { capture.setLens(stop) }
        }
        let report = scorer.update(m, now: now, placementError: placementError, exposureSettled: exposureSettled)
        self.scorer = scorer
        return report
    }

    /// AI 停止：回到系统自动曝光与对焦节奏；镜头与画幅保持用户可见的状态。
    func stop() {
        capture.releaseManualExposure()
        plan = nil
        scorer = nil
        lenses?.reset()
        springReady = false
        crop = .full
        lastFocus = nil
        lastTime = nil
        lastZoom = nil
        lastExposure = nil
        exposureSettled = false
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
