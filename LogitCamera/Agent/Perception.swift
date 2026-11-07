import CameraCore
import CoreVideo
import Foundation
import Vision

/// 本地感知：按快（100 ms）、中（250 ms）、慢（1 s）三档调度测量，算不过来就跳过，不排队。
/// 只在 AI 开启时运行。设备发热时降频（serious ×2，critical 停中慢档并清空缓存）。
/// 中、慢档结果带时间戳与 epoch，过期或停止前发起的结果不会被当成当前画面（审查 C1）。
actor Perception {
    private let frames: FrameGrabber
    private let detectors = VisionDetectors()
    private let motion = MotionMonitor()
    private var task: Task<Void, Never>?

    private var baseline: [UInt8]?
    private var wantsBaseline = true
    private var preferred: SubjectKind?
    /// 停止、换主体类型时加一；之前发起的检测结果与跟踪结果被丢弃（审查 C1）。
    private var epoch = 0
    private var faces = TierCache<[Subject]>()
    private var bodies = TierCache<[Subject]>()
    private var horizon = TierCache<Double?>()
    private var salient = TierCache<CameraCore.NormalizedRect?>()
    private var aesthetics = TierCache<AestheticsHint?>()
    private var tracker: TrackObjectRequest?
    private var tracked: (box: CameraCore.NormalizedRect, kind: SubjectKind)?
    private var lastPrimaryCenter: (point: CameraCore.NormalizedPoint, time: TimeInterval)?
    private var lastFrameTime: TimeInterval = 0
    private var midRunning = false
    private var slowRunning = false
    private var lastMid: TimeInterval = 0
    private var lastSlow: TimeInterval = 0
    private var thermalScale = 1.0
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
        resetDetections()
    }

    /// 下一帧作为场景变化的基线（新方案、拍摄之后）。
    func resetBaseline() { wantsBaseline = true }

    func setPreferredSubject(_ kind: SubjectKind?) {
        guard preferred != kind else { return }
        preferred = kind
        epoch += 1
        tracker = nil
        tracked = nil
    }

    private func resetDetections() {
        epoch += 1
        tracker = nil
        tracked = nil
        lastPrimaryCenter = nil
        faces.clear()
        bodies.clear()
        horizon.clear()
        salient.clear()
        aesthetics.clear()
    }

    // 中档每 0.25 秒、慢档每 1 秒；发热时间隔加倍，有效期随之放宽。
    private var midMaxAge: TimeInterval { 0.6 * thermalScale }
    private var slowMaxAge: TimeInterval { 1.5 * thermalScale }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: - Tick

    /// 处理一帧并返回距下一次的等待时间。
    private func tick(_ onMeasurement: @Sendable (SceneMeasurement) -> Void) async -> Double {
        let thermal = ProcessInfo.processInfo.thermalState
        thermalScale = thermal == .serious || thermal == .critical ? 2 : 1
        guard let (buffer, timestamp) = frames.latestBuffer(), timestamp > lastFrameTime else { return 0.05 }
        lastFrameTime = timestamp
        let frame = FrameBuffer(pixelBuffer: buffer, timestamp: timestamp)

        // 中、慢档在独立任务中运行，不阻塞快档；上一轮未完成就跳过。过热到 critical 时停用并清空缓存。
        if thermal == .critical {
            if tracked != nil || faces.value(now: now, epoch: epoch, maxAge: .infinity) != nil { resetDetections() }
        } else {
            if !midRunning, timestamp - lastMid >= 0.25 * thermalScale {
                lastMid = timestamp
                midRunning = true
                let started = epoch
                Task { await self.runMidTier(frame, epoch: started) }
            }
            if !slowRunning, timestamp - lastSlow >= 1.0 * thermalScale {
                lastSlow = timestamp
                slowRunning = true
                let started = epoch
                Task { await self.runSlowTier(frame, epoch: started) }
            }
        }
        let started = ProcessInfo.processInfo.systemUptime
        await updateTracking(frame)
        let trackingCost = (ProcessInfo.processInfo.systemUptime - started) * 1000
        trackingMilliseconds = trackingMilliseconds == 0 ? trackingCost : trackingMilliseconds * 0.9 + trackingCost * 0.1

        guard let luma = Self.luma(buffer) else { return 0.1 * thermalScale }
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
            horizonDegrees: horizon.value(now: now, epoch: epoch, maxAge: midMaxAge) ?? nil,
            deviceAngularSpeed: motion.angularSpeed,
            subjectSpeed: subjectSpeed(primary, at: timestamp),
            sceneChange: MeasurementMath.sceneChange(baseline ?? signature, signature),
            aesthetics: aesthetics.value(now: now, epoch: epoch, maxAge: slowMaxAge) ?? nil,
            chroma: Self.chroma(buffer))
        onMeasurement(measurement)

        let cost = (ProcessInfo.processInfo.systemUptime - started) * 1000
        fastTickMilliseconds = fastTickMilliseconds == 0 ? cost : fastTickMilliseconds * 0.9 + cost * 0.1
        return max(0.02, 0.1 * thermalScale - cost / 1000)
    }

    private func runSlowTier(_ frame: FrameBuffer, epoch started: Int) async {
        defer { slowRunning = false }
        let box = (try? await detectors.saliency(frame)) ?? nil
        let hint = try? await detectors.aesthetics(frame)
        guard started == epoch else { return }
        salient.store(box, at: now, epoch: started, current: epoch)
        aesthetics.store(hint, at: now, epoch: started, current: epoch)
        if box == nil, tracked?.kind == .salient {
            tracker = nil
            tracked = nil
        }
    }

    private func runMidTier(_ frame: FrameBuffer, epoch started: Int) async {
        defer { midRunning = false }
        let foundFaces = (try? await detectors.faces(frame)) ?? []
        var foundBodies: [Subject] = []
        if preferred == .body || (preferred == nil && foundFaces.isEmpty) {
            foundBodies = (try? await detectors.bodies(frame)) ?? []
        }
        let level = try? await detectors.horizon(frame)
        guard started == epoch else { return }
        faces.store(foundFaces, at: now, epoch: started, current: epoch)
        bodies.store(foundBodies, at: now, epoch: started, current: epoch)
        horizon.store(level ?? nil, at: now, epoch: started, current: epoch)
        // 新鲜检测里已经没有这一类主体：丢弃跟踪，避免跟着旧框「看见」已经离开的人。
        if let kind = tracked?.kind, (kind == .face && foundFaces.isEmpty) || (kind == .body && foundBodies.isEmpty && preferred == .body) {
            tracker = nil
            tracked = nil
        }
    }

    private var freshFaces: [Subject] { faces.value(now: now, epoch: epoch, maxAge: midMaxAge) ?? [] }
    private var freshBodies: [Subject] { bodies.value(now: now, epoch: epoch, maxAge: midMaxAge) ?? [] }
    private var freshSalient: CameraCore.NormalizedRect? { salient.value(now: now, epoch: epoch, maxAge: slowMaxAge) ?? nil }

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
        let started = epoch
        let result = try? await request.perform(on: frame.pixelBuffer, orientation: .up)
        // await 期间可能已经停止或换了主体类型：不写回旧状态。
        guard started == epoch, tracker === request else { return }
        if let result, result.confidence > 0.3 {
            tracked = (detectors.topLeft(result.boundingBox), current.kind)
        } else {
            tracker = nil
            tracked = nil
        }
    }

    private func detectedPrimary() -> Subject? {
        let faces = freshFaces, bodies = freshBodies
        let largestFace = faces.max { $0.box.area * ($0.faceQuality ?? 0.5) < $1.box.area * ($1.faceQuality ?? 0.5) }
        let largestBody = bodies.max { $0.box.area < $1.box.area }
        let salientSubject = freshSalient.map { Subject(id: 300, kind: .salient, box: $0, confidence: 0.5) }
        let ranked: [Subject] = switch preferred {
        case .face: [largestFace].compactMap { $0 }
        case .body: [largestBody, largestFace].compactMap { $0 }
        case .salient: [salientSubject].compactMap { $0 }
        case .none?: []
        case nil: [largestFace, largestBody, salientSubject].compactMap { $0 }
        }
        return ranked.first
    }

    /// 主体排在第一位（id 1，框来自跟踪），属性取自与之重叠的最新检测。
    private func currentSubjects() -> [Subject] {
        var others = freshFaces + freshBodies
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
    /// CbCr 平面按 48×64 网格采样（YCbCr 420 双平面），得到偏色、饱和度与上方亮度统计。
    static func chroma(_ buffer: CVPixelBuffer) -> ChromaStats? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(buffer) >= 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), cRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let cWidth = CVPixelBufferGetWidthOfPlane(buffer, 1), cHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
        guard width > 0, height > 0, cWidth > 0, cHeight > 0 else { return nil }
        let gw = 48, gh = 64
        var cb = [UInt8](repeating: 128, count: gw * gh), cr = cb, luma = cb
        let ySource = yBase.assumingMemoryBound(to: UInt8.self), cSource = cBase.assumingMemoryBound(to: UInt8.self)
        for gy in 0..<gh {
            let y = min(height - 1, (gy * height + height / 2) / gh)
            let cy = min(cHeight - 1, y * cHeight / height)
            for gx in 0..<gw {
                let x = min(width - 1, (gx * width + width / 2) / gw)
                let cx = min(cWidth - 1, x * cWidth / width)
                let i = gy * gw + gx
                luma[i] = ySource[y * yRow + x]
                cb[i] = cSource[cy * cRow + cx * 2]
                cr[i] = cSource[cy * cRow + cx * 2 + 1]
            }
        }
        return MeasurementMath.chroma(cb: cb, cr: cr, luma: luma, width: gw, height: gh)
    }

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
