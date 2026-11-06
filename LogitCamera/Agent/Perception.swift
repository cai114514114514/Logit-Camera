import CameraCore
import CoreVideo
import Foundation
import Vision

/// 本地感知：按快（100 ms）、中（250 ms）、慢（1 s）三档调度测量，算不过来就跳过，不排队。
/// 只在 AI 开启时运行。设备发热时降频（serious ×2，critical 停中慢档）。
actor Perception {
    private let frames: FrameGrabber
    private let detectors = VisionDetectors()
    private let motion = MotionMonitor()
    private var task: Task<Void, Never>?

    private var baseline: [UInt8]?
    private var wantsBaseline = true
    private var preferred: SubjectKind?
    private var faces: [Subject] = []
    private var bodies: [Subject] = []
    private var salient: CameraCore.NormalizedRect?
    private var horizon: Double?
    private var aesthetics: AestheticsHint?
    private var tracker: TrackObjectRequest?
    private var tracked: (box: CameraCore.NormalizedRect, kind: SubjectKind)?
    private var lastPrimaryCenter: (point: CameraCore.NormalizedPoint, time: TimeInterval)?
    private var lastFrameTime: TimeInterval = 0
    private var midRunning = false
    private var slowRunning = false
    private var lastMid: TimeInterval = 0
    private var lastSlow: TimeInterval = 0
    /// 快档单次耗时的滑动平均（毫秒），供诊断显示。
    private(set) var fastTickMilliseconds = 0.0
    /// 其中主体跟踪（Vision）所占的毫秒数。
    private(set) var trackingMilliseconds = 0.0

    init(frames: FrameGrabber) {
        self.frames = frames
    }

    func start(onMeasurement: @escaping @Sendable (SceneMeasurement) -> Void) {
        guard task == nil else { return }
        motion.start()
        wantsBaseline = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                let interval = await self?.tick(onMeasurement) ?? 0.1
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        motion.stop()
        tracker = nil
        tracked = nil
        faces = []
        bodies = []
        salient = nil
        horizon = nil
        aesthetics = nil
    }

    /// 下一帧作为场景变化的基线（新方案、放行、拍摄之后）。
    func resetBaseline() { wantsBaseline = true }

    func setPreferredSubject(_ kind: SubjectKind?) {
        guard preferred != kind else { return }
        preferred = kind
        tracker = nil
        tracked = nil
    }

    // MARK: - Tick

    /// 处理一帧并返回距下一次的等待时间。
    private func tick(_ onMeasurement: @Sendable (SceneMeasurement) -> Void) async -> Double {
        let thermal = ProcessInfo.processInfo.thermalState
        let scale: Double = thermal == .serious || thermal == .critical ? 2 : 1
        guard let (buffer, timestamp) = frames.latestBuffer(), timestamp > lastFrameTime else { return 0.05 }
        lastFrameTime = timestamp
        let frame = FrameBuffer(pixelBuffer: buffer, timestamp: timestamp)

        // 中、慢档在独立任务中运行，不阻塞快档；上一轮未完成就跳过。
        if thermal != .critical {
            if !midRunning, timestamp - lastMid >= 0.25 * scale {
                lastMid = timestamp
                midRunning = true
                Task { await self.runMidTier(frame) }
            }
            if !slowRunning, timestamp - lastSlow >= 1.0 * scale {
                lastSlow = timestamp
                slowRunning = true
                Task { await self.runSlowTier(frame) }
            }
        }
        let started = ProcessInfo.processInfo.systemUptime
        await updateTracking(frame)
        let tracked = (ProcessInfo.processInfo.systemUptime - started) * 1000
        trackingMilliseconds = trackingMilliseconds == 0 ? tracked : trackingMilliseconds * 0.9 + tracked * 0.1

        guard let luma = Self.luma(buffer) else { return 0.1 * scale }
        let signature = MeasurementMath.signature(luma)
        if wantsBaseline || baseline == nil {
            baseline = signature
            wantsBaseline = false
        }
        let subjects = currentSubjects()
        let primary = subjects.first
        let region = primary?.box
        let measurement = SceneMeasurement(
            timestamp: timestamp, subjects: subjects, primarySubjectID: primary?.id,
            luminance: MeasurementMath.luminance(luma, subject: region),
            sharpness: Sharpness(global: MeasurementMath.sharpness(luma, region: nil),
                                 subject: region.map { MeasurementMath.sharpness(luma, region: $0) }),
            horizonDegrees: horizon, deviceAngularSpeed: motion.angularSpeed,
            subjectSpeed: subjectSpeed(primary, at: timestamp),
            sceneChange: MeasurementMath.sceneChange(baseline ?? signature, signature),
            aesthetics: aesthetics)
        onMeasurement(measurement)

        let cost = (ProcessInfo.processInfo.systemUptime - started) * 1000
        fastTickMilliseconds = fastTickMilliseconds == 0 ? cost : fastTickMilliseconds * 0.9 + cost * 0.1
        return max(0.02, 0.1 * scale - cost / 1000)
    }

    private func runSlowTier(_ frame: FrameBuffer) async {
        defer { slowRunning = false }
        salient = try? await detectors.saliency(frame)
        aesthetics = try? await detectors.aesthetics(frame)
    }

    private func runMidTier(_ frame: FrameBuffer) async {
        defer { midRunning = false }
        faces = (try? await detectors.faces(frame)) ?? []
        if preferred == .body || (preferred == nil && faces.isEmpty) {
            bodies = (try? await detectors.bodies(frame)) ?? []
        } else {
            bodies = []
        }
        horizon = try? await detectors.horizon(frame)
    }

    /// 主体选择：方案指定的类型优先，否则人脸 > 人体 > 显著区域；选中后用 TrackObjectRequest 跟踪。
    private func updateTracking(_ frame: FrameBuffer) async {
        let candidate = detectedPrimary()
        if let candidate {
            let isNew = tracked.map { iou($0.box, candidate.box) < 0.3 || $0.kind != candidate.kind } ?? true
            if isNew || tracker == nil {
                tracker = TrackObjectRequest(detectedObject: DetectedObjectObservation(boundingBox: detectors.visionRect(candidate.box)))
                tracked = (candidate.box, candidate.kind)
                return
            }
        }
        guard let request = tracker, let current = tracked else { return }
        if let result = try? await request.perform(on: frame.pixelBuffer, orientation: .up), result.confidence > 0.3 {
            tracked = (detectors.topLeft(result.boundingBox), current.kind)
        } else if candidate == nil {
            tracker = nil
            tracked = nil
        }
    }

    private func detectedPrimary() -> Subject? {
        let ranked: [Subject] = {
            let largestFace = faces.max { $0.box.area * ($0.faceQuality ?? 0.5) < $1.box.area * ($1.faceQuality ?? 0.5) }
            let largestBody = bodies.max { $0.box.area < $1.box.area }
            let salientSubject = salient.map { Subject(id: 300, kind: .salient, box: $0, confidence: 0.5) }
            switch preferred {
            case .face: return [largestFace].compactMap { $0 }
            case .body: return [largestBody, largestFace].compactMap { $0 }
            case .salient: return [salientSubject].compactMap { $0 }
            case .none?: return []
            case nil: return [largestFace, largestBody, salientSubject].compactMap { $0 }
            }
        }()
        return ranked.first
    }

    /// 主体排在第一位（id 1，框来自跟踪），属性取自与之重叠的最新检测。
    private func currentSubjects() -> [Subject] {
        var others = faces + bodies
        guard let tracked else { return others }
        let match = others.filter { $0.kind == tracked.kind }.max { iou($0.box, tracked.box) < iou($1.box, tracked.box) }
        var primary = match ?? Subject(id: 1, kind: tracked.kind, box: tracked.box, confidence: 0.5)
        primary.id = 1
        primary.box = tracked.box
        if let match { others.removeAll { $0.id == match.id } }
        return [primary] + others
    }

    private func subjectSpeed(_ primary: Subject?, at time: TimeInterval) -> Double {
        guard let primary else { lastPrimaryCenter = nil; return 0 }
        defer { lastPrimaryCenter = (primary.box.center, time) }
        guard let last = lastPrimaryCenter, time > last.time else { return 0 }
        let dx = primary.box.center.x - last.point.x, dy = primary.box.center.y - last.point.y
        return (dx * dx + dy * dy).squareRoot() / (time - last.time)
    }

    private func iou(_ a: CameraCore.NormalizedRect, _ b: CameraCore.NormalizedRect) -> Double {
        let x0 = max(a.x, b.x), y0 = max(a.y, b.y)
        let x1 = min(a.x + a.width, b.x + b.width), y1 = min(a.y + a.height, b.y + b.height)
        let intersection = max(0, x1 - x0) * max(0, y1 - y0)
        let union = a.area + b.area - intersection
        return union > 0 ? intersection / union : 0
    }

    // MARK: - Luma

    /// Y 平面按步长采样为长边约 320 的灰度图（每个输出像素取 2×2 个采样点的平均）。
    /// 全分辨率帧上做高质量重采样太贵；这些测量不需要高质量缩放。
    static func luma(_ buffer: CVPixelBuffer) -> LumaImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(buffer) >= 1, let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let step = max(1, max(width, height) / 320)
        let outWidth = max(1, width / step), outHeight = max(1, height / step)
        let half = max(1, step / 2)
        let source = base.assumingMemoryBound(to: UInt8.self)
        var bytes = [UInt8](repeating: 0, count: outWidth * outHeight)
        bytes.withUnsafeMutableBufferPointer { out in
            guard let o = out.baseAddress else { return }
            for y in 0..<outHeight {
                let y0 = y * step, y1 = min(height - 1, y0 + half)
                let row0 = source + y0 * rowBytes, row1 = source + y1 * rowBytes
                for x in 0..<outWidth {
                    let x0 = x * step, x1 = min(width - 1, x0 + half)
                    let sum = Int(row0[x0]) + Int(row0[x1]) + Int(row1[x0]) + Int(row1[x1])
                    o[y * outWidth + x] = UInt8(sum >> 2)
                }
            }
        }
        return LumaImage(width: outWidth, height: outHeight, bytes: bytes)
    }
}
