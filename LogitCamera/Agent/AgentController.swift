import CameraCore
import Foundation
import Observation

/// 决策记录（详情面板显示最近 10 条）。
struct AgentLogEntry: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let text: String
}

/// AI 的总控：调度器（何时问云端、何时拍）+ 感知（测量）+ 执行（镜头、曝光、对焦、构图、时机）+ 模型。
/// 云端只给意图；按快门的时机完全由本机决定，用户的快门永远可用。
@MainActor @Observable
final class AgentController {
    private(set) var isEnabled = false
    private(set) var phase: AgentPhase = .off
    private(set) var plan: ShotPlan?
    private(set) var isDefaultPlan = true
    private(set) var isOffline = false
    private(set) var genreName: String?
    /// 导演对最近一帧的量表点评（只用于展示）。
    private(set) var critique: RubricResult?
    private(set) var rubricWeights: [RubricCriterion: Double] = [:]
    private(set) var moment: MomentReport?
    private(set) var crop: CameraCore.NormalizedRect?
    private(set) var subjectBox: CameraCore.NormalizedRect?
    private(set) var lens: LensStop?
    /// AI 此刻要说的一句人话（字幕）；nil 表示不显示。
    private(set) var caption: String?
    /// 每次真正截取一帧发给模型时加一，驱动取景扫描线。
    private(set) var observationTick = 0
    private(set) var calls = 0
    private(set) var faulted = false
    private(set) var status = "AI 待命"
    private(set) var reason = ""
    private(set) var history: [AgentLogEntry] = []
    /// 仅调试：感知诊断文字（-LogitPerceptionOnly）。发布版始终为空。
    private(set) var diagnostics: String?
    var autoCaptureEnabled = true
    let modelName = AICredentials.displayName

    /// 相机最新状态，由 CameraModel 推送。
    @ObservationIgnored var cameraState = CameraState()
    /// 触发自动拍摄（裁切框与画幅一起冻结）；返回 false 表示相机暂时不能拍。
    @ObservationIgnored var onFire: ((CameraCore.NormalizedRect?, FrameRatio) -> Bool)?
    /// 新方案生效（用于把读数标为 AI 设定）。
    @ObservationIgnored var onPlanApplied: ((ShotPlan) -> Void)?
    @ObservationIgnored var demoLocked = false

    @ObservationIgnored private let capture: CaptureSession
    @ObservationIgnored private let perception: Perception
    @ObservationIgnored private let executor: Executor
    /// 调度器只创建一次：请求编号跨开关单调递增，旧回复永远对不上号（审查 I7）。
    @ObservationIgnored private var scheduler: DirectorScheduler?
    @ObservationIgnored private var model: VisionModel?
    @ObservationIgnored private var memory: DirectorMemory?
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private var latest: SceneMeasurement?
    /// 感知层操作串行执行，保证 stop / start / resetBaseline 的顺序。
    @ObservationIgnored private var perceptionChain: Task<Void, Never>?
    @ObservationIgnored private var captions = CaptionDirector()
    @ObservationIgnored private var pickedAt: TimeInterval?

    init(capture: CaptureSession) {
        self.capture = capture
        perception = Perception(frames: capture.frames)
        executor = Executor(capture: capture)
    }

    // MARK: - Lifecycle

    func enable(key: String) {
        guard !demoLocked else { return }
        if scheduler == nil {
            do { scheduler = try DirectorScheduler.live() } catch {
                faulted = true
                status = "知识库加载失败"
                return
            }
        }
        model = Self.makeModel(key: key)
        isEnabled = true
        faulted = false
        calls = 0
        history = []
        memory = nil
        critique = nil
        latest = nil
        moment = nil
        log("AI 开启")
        startPerception()
        handle(.start)
    }

    private static func makeModel(key: String) -> VisionModel {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-LogitOfflineDirector") { return OfflineDirector() }
        #endif
        return DeepSeekAdapter(key: key)
    }

    func stop() {
        guard isEnabled || faulted else { return }
        request?.cancel()
        request = nil
        if var scheduler {
            _ = scheduler.handle(.stop, now: now)
            self.scheduler = scheduler
        }
        perceptionDo { await $0.stop() }
        executor.stop()
        isEnabled = false
        faulted = false
        isOffline = false
        phase = .off
        plan = nil
        crop = nil
        subjectBox = nil
        moment = nil
        lens = nil
        caption = nil
        captions = CaptionDirector()
        status = "AI 待命"
        reason = ""
    }

    /// 后台、相机中断：停止感知与请求，保留方案。
    func pause() {
        guard isEnabled, phase != .paused else { return }
        request?.cancel()
        request = nil
        perceptionDo { await $0.stop() }
        handle(.pause)
        caption = nil
    }

    func resume() {
        guard isEnabled, phase == .paused, !demoLocked else { return }
        startPerception()
        handle(.resume)
    }

    func setAutoCapture(_ enabled: Bool) { autoCaptureEnabled = enabled }
    /// 冷却中「再拍一张」。
    func rearm() { handle(.rearm) }

    /// 照片已拍下（自动或手动）：立即进入冷却，避免选片期间又自动拍一组。
    func captured(automatic: Bool) {
        guard isEnabled else { return }
        log(automatic ? "已自动拍摄" : "已拍摄")
        handle(.captured)
    }

    /// 选片完成后记下拍摄依据（意图、测量、点评）。
    func record(photoID: UUID, automatic: Bool) {
        guard isEnabled || plan != nil else { return }
        let record = CaptureRecord(photoID: photoID, date: Date(), plan: plan, measurement: latest, rubric: critique,
                                   automatic: automatic, chosenIndex: nil)
        Task { await CaptureRecordStore.shared.append(record) }
    }

    func fireRejected() { handle(.fireRejected) }

    /// 选片完成（CameraModel 调用）：字幕说明挑了哪一张。
    func picked() {
        guard isEnabled else { return }
        pickedAt = now
        refreshCaption()
    }

    private func refreshCaption() {
        guard isEnabled, !demoLocked else { return }
        let waiting = moment?.statuses.first { $0.available && !$0.satisfied }?.trigger.kind
        let snapshot = CaptionSnapshot(
            phase: phase, isOffline: isOffline, genre: plan?.genre, genreName: genreName,
            isDefaultPlan: isDefaultPlan, planID: plan?.id, rationale: plan?.rationale, lens: lens,
            depth: plan?.exposure.depth, waitingFor: waiting, starved: executor.lastExposure?.starved ?? false,
            pickedAt: pickedAt)
        let text = captions.update(snapshot, now: now)
        if text != caption { caption = text }
    }

    // MARK: - Measurement loop

    private func startPerception() {
        let sink: @Sendable (SceneMeasurement) -> Void = { [weak self] measurement in
            Task { @MainActor in self?.ingest(measurement) }
        }
        perceptionDo { await $0.start(onMeasurement: sink) }
    }

    private func perceptionDo(_ operation: @escaping @Sendable (Perception) async -> Void) {
        let previous = perceptionChain
        perceptionChain = Task { [perception] in
            await previous?.value
            await operation(perception)
        }
    }

    private func ingest(_ m: SceneMeasurement) {
        guard isEnabled, phase != .paused, phase != .off else { return }
        latest = m
        guard var report = executor.ingest(m, state: cameraState, now: now) else { return }
        crop = executor.crop
        subjectBox = m.primarySubject?.box
        lens = executor.lens
        // 关闭自动拍摄时仍显示时机分，但不触发快门，由用户自己按。
        if !autoCaptureEnabled { report = report.withoutFire }
        moment = report
        handle(.measurement(m, report))
        refreshCaption()
    }

    // MARK: - Scheduler

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func handle(_ event: SchedulerEvent) {
        guard var scheduler else { return }
        let output = scheduler.handle(event, now: now)
        self.scheduler = scheduler
        if output.resetMemory { memory = nil }
        if output.resetBaseline { perceptionDo { await $0.resetBaseline() } }
        sync(scheduler)
        refreshCaption()
        if output.restartMoment { executor.restartMoment(at: now) }
        guard let id = output.requestID else {
            if output.command == .fire { fire() }
            return
        }
        switch output.command {
        case .callScout: callScout(id: id)
        case .callDirector(let genre, let feedback): callDirector(genre, feedback: feedback, id: id)
        case .fire: fire()
        case .none: break
        }
    }

    private func fire() {
        let ratio = plan?.composition.ratio ?? cameraState.ratio
        if onFire?(crop, ratio) != true { handle(.fireRejected) }
    }

    private func sync(_ scheduler: DirectorScheduler) {
        phase = scheduler.phase
        isOffline = scheduler.isOffline
        if scheduler.phase == .off, isEnabled {
            // 不可重试的错误（密钥、额度）使调度器停止。
            isEnabled = false
            faulted = true
            status = "AI 需要检查密钥"
            perceptionDo { await $0.stop() }
            executor.stop()
            return
        }
        if let newPlan = scheduler.plan, newPlan.id != plan?.id {
            plan = newPlan
            isDefaultPlan = scheduler.isDefaultPlan
            executor.apply(newPlan, state: cameraState, now: now)
            let playbook = try? Knowledge.playbook(newPlan.genre)
            genreName = playbook?.name
            rubricWeights = playbook?.rubricWeights ?? [:]
            let preferred: SubjectKind? = newPlan.subject == .none ? nil : newPlan.subject
            perceptionDo { await $0.setPreferredSubject(preferred) }
            onPlanApplied?(newPlan)
            if !isDefaultPlan { log("新方案：\(genreName ?? newPlan.genre.rawValue) · \(newPlan.rationale)") }
        }
        if !faulted { status = statusText() }
    }

    private func statusText() -> String {
        if isOffline, [.composing, .planning].contains(phase) { return "离线 · 本机取景" }
        return Self.statusText(phase)
    }

    static func statusText(_ phase: AgentPhase) -> String {
        switch phase {
        case .off: "AI 待命"
        case .scouting: "观察中"
        case .planning: "构思中"
        case .composing: "取景中"
        case .capturing: "拍摄中"
        case .cooldown: "已拍摄 · 场景变化后继续"
        case .paused: "已暂停"
        }
    }

    // MARK: - Model calls

    /// 回复必须对上当前在途的请求编号，且 AI 仍在运行，才允许修改任何状态。
    private func isCurrent(_ id: Int) -> Bool {
        isEnabled && scheduler?.inFlightID == id
    }

    private func callScout(id: Int) {
        guard let model else { return failQuietly(id) }
        let plan = isDefaultPlan ? nil : self.plan
        request = Task { [weak self] in
            guard let self else { return }
            guard let (frame, signature) = await self.frame(maxDimension: 768) else {
                return self.failQuietly(id)
            }
            guard self.isCurrent(id) else { return }
            self.observationTick += 1
            self.calls += 1
            do {
                let result = try await model.scout(frame, plan: plan)
                guard self.isCurrent(id) else { return }
                guard await self.isFresh(frame, signature: signature) else {
                    self.log("画面已变化，丢弃侦察结果")
                    return self.handle(.requestFailed(id: id, retryable: true, stale: true))
                }
                guard self.isCurrent(id) else { return }
                self.log("侦察：\(result.genre.rawValue) · \(result.reason)")
                self.handle(.scoutReply(id: id, result))
            } catch {
                self.fail(error, id: id)
            }
        }
    }

    private func callDirector(_ genre: GenreID, feedback: String?, id: Int) {
        guard let model, let playbook = try? Knowledge.playbook(genre) else { return failQuietly(id) }
        let currentPlan = isDefaultPlan ? nil : plan
        let text = executionFeedback(feedback)
        let memory = self.memory
        request = Task { [weak self] in
            guard let self else { return }
            guard let (frame, signature) = await self.frame(maxDimension: 1280) else {
                return self.failQuietly(id)
            }
            guard self.isCurrent(id) else { return }
            self.observationTick += 1
            self.calls += 1
            do {
                let outcome = try await model.direct(frame, playbook: playbook, plan: currentPlan, memory: memory, feedback: text)
                guard self.isCurrent(id) else { return }
                guard await self.isFresh(frame, signature: signature) else {
                    self.log("画面已变化，丢弃导演方案")
                    return self.handle(.requestFailed(id: id, retryable: true, stale: true))
                }
                guard self.isCurrent(id) else { return }
                self.memory = outcome.memory
                self.critique = outcome.critique
                self.reason = outcome.plan.rationale
                self.log(String(format: "点评：%.1f 分", outcome.critique.weighted(playbook.rubricWeights)))
                self.handle(.directorReply(id: id, .plan(outcome.plan, outcome.critique)))
            } catch ModelError.invalidPlan(let detail) {
                guard self.isCurrent(id) else { return }
                self.log("方案未通过校验：\(detail)")
                self.handle(.directorReply(id: id, .invalid(detail)))
            } catch {
                self.fail(error, id: id)
            }
        }
    }

    /// 早返回也必须释放在途请求，否则调度器会一直等下去。
    private func failQuietly(_ id: Int) {
        guard isCurrent(id) else { return }
        handle(.requestFailed(id: id, retryable: true, stale: true))
    }

    private func fail(_ error: Error, id: Int) {
        if error is CancellationError { return }
        guard isCurrent(id) else { return }
        let modelError = error as? ModelError
        let retryable = modelError?.isRetryable ?? true
        reason = (error as? LocalizedError)?.errorDescription ?? describe(modelError)
        log("请求失败：\(reason)")
        faulted = !retryable
        handle(.requestFailed(id: id, retryable: retryable, stale: false))
        if !retryable {
            status = "AI 需要检查密钥"
            reason = "密钥无效或账户额度不足，请检查 AI 设置。"
        }
    }

    private func describe(_ error: ModelError?) -> String {
        switch error {
        case .authentication?: "密钥无效或额度不足"
        case .rateLimited?: "请求受限，稍后重试"
        case .http(let code)?: "服务暂时不可用（HTTP \(code)）"
        case .truncated?, .noToolCall?, .multipleToolCalls?, .unexpectedTool?, .schema?: "模型回复格式不符，将重试"
        case .invalidPlan(let detail)?: "方案超出设备能力（\(detail)）"
        case .transport?: "网络连接失败"
        case nil: "未知错误"
        }
    }

    /// 发给模型的一帧：直立 JPEG + 最新测量 + 设备能力。截图在后台完成。
    private func frame(maxDimension: CGFloat) async -> (ModelFrame, [UInt8])? {
        // 刚开启时感知层可能还没有第一帧测量：最多等 1 秒。
        for _ in 0..<20 where latest == nil { try? await Task.sleep(for: .milliseconds(50)) }
        let frames = capture.frames
        guard let measurement = latest, let limits = await capture.currentLimits(),
              let snapshot = await Task.detached(priority: .userInitiated, operation: {
                  try? frames.snapshot(maxDimension: maxDimension)
              }).value else { return nil }
        return (ModelFrame(jpeg: snapshot.jpeg, measurement: measurement, limits: limits, timestamp: snapshot.timestamp),
                snapshot.signature)
    }

    /// 过期丢弃：响应对应的帧超过 12 秒，或画面已明显变化。签名在后台计算，不占主线程。
    private func isFresh(_ frame: ModelFrame, signature: [UInt8]) async -> Bool {
        guard now - frame.timestamp <= 12 else { return false }
        let frames = capture.frames
        let current = await Task.detached(priority: .utility) { try? frames.snapshot(maxDimension: 64).signature }.value
        guard let current else { return true }
        return MeasurementMath.sceneChange(signature, current) <= DirectorScheduler.sceneChangeThreshold
    }

    /// 给导演的本机反馈：上一次方案的校验错误，加上执行情况。
    private func executionFeedback(_ validation: String?) -> String {
        var parts: [String] = []
        if let validation { parts.append("上一次方案未通过校验：\(validation)。请修正后重新给出完整方案。") }
        if let lens = executor.lens { parts.append("当前镜头 \(Int(lens.focalLength))mm") }
        if let decision = executor.lastExposure {
            parts.append(decision.starved ? "光线不足（ISO 已到上限）" : (decision.settled ? "曝光已收敛" : "曝光调整中"))
        }
        if let moment { parts.append(String(format: "时机分 %.2f", moment.score)) }
        return parts.joined(separator: "；")
    }

    private func log(_ text: String) {
        history.insert(AgentLogEntry(date: Date(), text: text), at: 0)
        if history.count > 10 { history.removeLast(history.count - 10) }
        AgentTrace.record(text)
    }

    #if DEBUG
    func showDiagnostics(_ text: String) {
        demoLocked = true
        diagnostics = text
    }

    /// 只运行感知层（不调用模型、不改硬件），在取景上显示测量与耗时，用于真机检查。
    func startPerceptionProbe() {
        demoLocked = true
        diagnostics = "感知启动中…"
        let sink: @Sendable (SceneMeasurement) -> Void = { [weak self] measurement in
            Task { @MainActor in self?.probe(measurement) }
        }
        perceptionDo { await $0.start(onMeasurement: sink) }
    }

    @ObservationIgnored private var lastProbe: TimeInterval = 0

    private func probe(_ m: SceneMeasurement) {
        latest = m
        subjectBox = m.primarySubject?.box
        guard now - lastProbe > 0.5 else { return }
        lastProbe = now
        Task { [perception] in
            let cost = await perception.fastTickMilliseconds
            let tracking = await perception.trackingMilliseconds
            let s = m.primarySubject
            let lines = [
                String(format: "快档 %.1f ms（跟踪 %.1f）", cost, tracking),
                "主体 \(s?.kind.rawValue ?? "—")" + (s.map { String(format: " %.2f×%.2f", $0.box.width, $0.box.height) } ?? ""),
                s?.eyeOpenness.map { String(format: "睁眼 %.2f", $0) } ?? "睁眼 —",
                s?.yaw.map { String(format: "yaw %.0f°", $0) } ?? "yaw —",
                m.horizonDegrees.map { String(format: "地平线 %.1f°", $0) } ?? "地平线 —",
                String(format: "清晰 %.2f / %.2f", m.sharpness.global, m.sharpness.subject ?? -1),
                String(format: "亮度 %.2f 高光 %.2f%%", m.luminance.mean, m.luminance.clipHigh * 100),
                String(format: "抖动 %.3f 变化 %.3f", m.deviceAngularSpeed, m.sceneChange),
                m.aesthetics.map { String(format: "美学 %.2f %@", $0.score, $0.labels.prefix(3).joined(separator: ",")) } ?? "美学 —"
            ]
            await MainActor.run { self.diagnostics = lines.joined(separator: "\n") }
        }
    }

    /// 演示模式：直接设置展示字段，不启动调度器、感知与网络。
    func setDemo(phase: AgentPhase, plan: ShotPlan?, genreName: String?, critique: RubricResult?,
                 moment: MomentReport?, crop: CameraCore.NormalizedRect?, subject: CameraCore.NormalizedRect?,
                 lens: LensStop? = nil, reason: String, faulted: Bool = false, offline: Bool = false, tick: Bool = false,
                 caption: String? = nil) {
        demoLocked = true
        isEnabled = phase != .off
        self.phase = phase
        self.plan = plan
        isDefaultPlan = plan == nil
        isOffline = offline
        self.genreName = genreName
        self.critique = critique
        rubricWeights = plan.flatMap { try? Knowledge.playbook($0.genre).rubricWeights } ?? [:]
        self.moment = moment
        self.crop = crop
        self.lens = lens
        self.caption = caption
        subjectBox = subject
        self.reason = reason
        self.faulted = faulted
        status = faulted ? "AI 需要检查密钥" : statusText()
        if tick { observationTick += 1; calls += 1 }
        if let plan, history.isEmpty { history = [AgentLogEntry(date: Date(), text: "新方案：\(genreName ?? "") · \(plan.rationale)")] }
    }
    #endif
}
