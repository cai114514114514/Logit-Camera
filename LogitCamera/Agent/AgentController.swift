import CameraCore
import Foundation
import Observation

/// 决策记录（详情面板显示最近 10 条）。
struct AgentLogEntry: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let text: String
}

/// AI 的总控：调度器（何时问模型、何时拍）+ 感知（测量）+ 执行（对焦、曝光、构图）+ 模型。
/// 模型只给方案和评分；没有评审放行永不自动拍摄。
@MainActor @Observable
final class AgentController {
    private(set) var isEnabled = false
    private(set) var phase: AgentPhase = .off
    private(set) var plan: ShotPlan?
    private(set) var isDefaultPlan = true
    private(set) var genreName: String?
    private(set) var rubric: RubricResult?
    private(set) var rubricWeights: [RubricCriterion: Double] = [:]
    private(set) var report: TriggerReport?
    private(set) var crop: CameraCore.NormalizedRect?
    private(set) var subjectBox: CameraCore.NormalizedRect?
    /// 每次真正截取一帧发给模型时加一，驱动取景扫描线。
    private(set) var observationTick = 0
    private(set) var calls = 0
    private(set) var faulted = false
    private(set) var status = "AI 待命"
    private(set) var reason = ""
    private(set) var history: [AgentLogEntry] = []
    var autoCaptureEnabled = true
    let modelName = AICredentials.displayName

    /// 相机最新状态，由 CameraModel 推送。
    @ObservationIgnored var cameraState = CameraState()
    /// 触发拍摄；返回 false 表示相机暂时不能拍。
    @ObservationIgnored var onFire: ((CameraCore.NormalizedRect?) -> Bool)?
    /// 新方案生效（用于把读数标为 AI 设定、同步画幅）。
    @ObservationIgnored var onPlanApplied: ((ShotPlan) -> Void)?
    @ObservationIgnored var demoLocked = false

    @ObservationIgnored private let capture: CaptureSession
    @ObservationIgnored private let perception: Perception
    @ObservationIgnored private let executor: Executor
    @ObservationIgnored private var scheduler: DirectorScheduler?
    @ObservationIgnored private var model: VisionModel?
    @ObservationIgnored private var memory: JudgeMemory?
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private var latest: SceneMeasurement?
    /// 感知层操作串行执行，保证 stop / start / resetBaseline 的顺序。
    @ObservationIgnored private var perceptionChain: Task<Void, Never>?

    init(capture: CaptureSession) {
        self.capture = capture
        perception = Perception(frames: capture.frames)
        executor = Executor(capture: capture)
    }

    // MARK: - Lifecycle

    func enable(key: String) {
        guard !demoLocked else { return }
        do { scheduler = try DirectorScheduler.live() } catch {
            faulted = true
            status = "知识库加载失败"
            return
        }
        model = DeepSeekAdapter(key: key)
        isEnabled = true
        faulted = false
        calls = 0
        history = []
        memory = nil
        rubric = nil
        log("AI 开启")
        startPerception()
        handle(.start)
    }

    func stop() {
        guard isEnabled || faulted else { return }
        request?.cancel()
        request = nil
        _ = scheduler?.handle(.stop, now: now)
        perceptionDo { await $0.stop() }
        executor.stop(state: cameraState)
        isEnabled = false
        faulted = false
        phase = .off
        plan = nil
        crop = nil
        subjectBox = nil
        report = nil
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
    }

    func resume() {
        guard isEnabled, phase == .paused, !demoLocked else { return }
        startPerception()
        handle(.resume)
    }

    func setAutoCapture(_ enabled: Bool) { autoCaptureEnabled = enabled }
    /// 冷却中「再拍一张」。
    func rearm() { handle(.rearm) }
    /// 就绪时点快门：本场景不再自动拍摄。
    func disarm() { handle(.disarm) }

    /// 照片已拍下（自动拍摄才计入冷却并保存拍摄依据）。
    func captured(photoID: UUID, automatic: Bool) {
        guard isEnabled else { return }
        if automatic {
            CaptureRecordStore.append(CaptureRecord(photoID: photoID, date: Date(), plan: plan, measurement: latest,
                                                    rubric: rubric, automatic: true))
            log("已拍摄")
            handle(.captured)
        }
    }

    func fireRejected() { handle(.fireRejected) }

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
        guard isEnabled, phase != .paused else { return }
        latest = m
        guard var report = executor.ingest(m, state: cameraState, now: now) else { return }
        crop = isDefaultPlan ? nil : executor.crop
        subjectBox = m.primarySubject?.box
        if !autoCaptureEnabled {
            // 关闭自动拍摄时仍提示「就绪」，但不触发快门，由用户自己按。
            report = TriggerReport(statuses: report.statuses, allSatisfied: report.allSatisfied,
                                   sustained: false, nearlyReady: report.nearlyReady)
        }
        self.report = report
        handle(.measurement(m, report))
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
        switch output.command {
        case .none: break
        case .callScout: callScout(generation: scheduler.generation)
        case .callJudge(let mode): callJudge(mode, generation: scheduler.generation)
        case .fire:
            if onFire?(crop) != true { handle(.fireRejected) }
        }
    }

    private func sync(_ scheduler: DirectorScheduler) {
        phase = scheduler.phase
        if scheduler.phase == .off, isEnabled {
            // 不可重试的错误（密钥、额度）使调度器停止。
            isEnabled = false
            faulted = true
            status = "AI 需要检查密钥"
            perceptionDo { await $0.stop() }
            executor.stop(state: cameraState)
            return
        }
        if let newPlan = scheduler.plan, newPlan.id != plan?.id {
            plan = newPlan
            isDefaultPlan = scheduler.isDefaultPlan
            executor.apply(newPlan, isDefault: isDefaultPlan)
            let playbook = try? Knowledge.playbook(newPlan.genre)
            genreName = isDefaultPlan ? nil : playbook?.name
            rubricWeights = playbook?.rubricWeights ?? [:]
            let preferred: SubjectKind? = isDefaultPlan ? nil : newPlan.subject
            perceptionDo { await $0.setPreferredSubject(preferred) }
            if !isDefaultPlan {
                onPlanApplied?(newPlan)
                log("新方案：\(genreName ?? newPlan.genre.rawValue) · \(newPlan.rationale)")
            }
        }
        if !faulted { status = Self.statusText(phase) }
    }

    static func statusText(_ phase: AgentPhase) -> String {
        switch phase {
        case .off: "AI 待命"
        case .scouting: "侦察中"
        case .planning: "制定方案"
        case .tracking: "跟踪中"
        case .reviewing: "复核中"
        case .armed: "就绪"
        case .capturing: "拍摄中"
        case .cooldown: "已拍摄 · 场景变化后继续"
        case .paused: "已暂停"
        }
    }

    // MARK: - Model calls

    private func callScout(generation: Int) {
        guard let model else { return }
        let plan = isDefaultPlan ? nil : self.plan
        request = Task { [weak self] in
            guard let self, let frame = await self.frame(maxDimension: 768) else {
                self?.handle(.requestFailed(generation: generation, retryable: true))
                return
            }
            self.observationTick += 1
            self.calls += 1
            do {
                let result = try await model.scout(frame, plan: plan)
                guard self.isFresh(frame) else {
                    self.log("画面已变化，丢弃侦察结果")
                    self.handle(.requestFailed(generation: generation, retryable: true))
                    return
                }
                self.log("侦察：\(result.genre.rawValue) · \(result.reason)")
                self.handle(.scoutReply(generation: generation, result))
            } catch {
                self.fail(error, generation: generation)
            }
        }
    }

    private func callJudge(_ mode: JudgeMode, generation: Int) {
        guard let model else { return }
        let genre: GenreID
        switch mode {
        case .plan(let g): genre = g
        case .approve: genre = plan?.genre ?? .general
        }
        guard let playbook = try? Knowledge.playbook(genre) else { return }
        let currentPlan = isDefaultPlan ? nil : plan
        let feedback = feedbackText()
        let memory = self.memory
        request = Task { [weak self] in
            guard let self, let frame = await self.frame(maxDimension: 1280) else {
                self?.handle(.requestFailed(generation: generation, retryable: true))
                return
            }
            self.observationTick += 1
            self.calls += 1
            do {
                let outcome = try await model.judge(frame, playbook: playbook, plan: currentPlan, memory: memory, feedback: feedback)
                guard self.isFresh(frame) else {
                    self.log("画面已变化，丢弃评审结果")
                    self.handle(.requestFailed(generation: generation, retryable: true))
                    return
                }
                self.memory = outcome.memory
                switch outcome.result {
                case .setPlan(let plan, let rubric):
                    self.rubric = rubric
                    self.reason = plan.rationale
                case .keepPlan(let rubric, let reason):
                    self.rubric = rubric
                    self.reason = reason
                }
                if let rubric = self.rubric {
                    self.log(String(format: "评审：%.1f 分 · %@", rubric.weighted(playbook.rubricWeights), self.reason))
                }
                self.handle(.judgeReply(generation: generation, outcome.result))
            } catch {
                self.fail(error, generation: generation)
            }
        }
    }

    private func fail(_ error: Error, generation: Int) {
        if error is CancellationError { return }
        let modelError = error as? ModelError
        let retryable = modelError?.isRetryable ?? true
        reason = (error as? LocalizedError)?.errorDescription ?? describe(modelError)
        log("请求失败：\(reason)")
        faulted = !retryable
        handle(.requestFailed(generation: generation, retryable: retryable))
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

    /// 发给模型的一帧：直立 JPEG + 最新测量 + 设备能力。
    private func frame(maxDimension: CGFloat) async -> ModelFrame? {
        // 刚开启时感知层可能还没有第一帧测量：最多等 1 秒。
        for _ in 0..<20 where latest == nil { try? await Task.sleep(for: .milliseconds(50)) }
        let frames = capture.frames
        guard let measurement = latest, let limits = await capture.currentLimits(),
              let snapshot = await Task.detached(priority: .userInitiated, operation: {
                  try? frames.snapshot(maxDimension: maxDimension)
              }).value else { return nil }
        requestSignature = snapshot.signature
        return ModelFrame(jpeg: snapshot.jpeg, measurement: measurement, limits: limits, timestamp: snapshot.timestamp)
    }

    @ObservationIgnored private var requestSignature: [UInt8]?

    /// 过期丢弃：响应对应的帧超过 12 秒，或画面已明显变化。
    private func isFresh(_ frame: ModelFrame) -> Bool {
        guard now - frame.timestamp <= 12 else { return false }
        guard let before = requestSignature, let current = try? capture.frames.snapshot(maxDimension: 64) else { return true }
        return MeasurementMath.sceneChange(before, current.signature) <= DirectorScheduler.sceneChangeThreshold
    }

    /// 给评审的本地执行反馈：条件状态与曝光是否收敛。
    private func feedbackText() -> String {
        guard let report else { return "" }
        let items = report.statuses.map { status -> String in
            let threshold = status.trigger.threshold.map { String(format: "%.2f", $0) } ?? ""
            return "\(status.trigger.kind.rawValue)\(threshold.isEmpty ? "" : "(\(threshold))") \(status.satisfied ? "满足" : "未满足")"
        }
        return "拍摄条件：" + items.joined(separator: "，") + (executor.exposureSettled ? "；曝光已收敛" : "；曝光调整中")
    }

    private func log(_ text: String) {
        history.insert(AgentLogEntry(date: Date(), text: text), at: 0)
        if history.count > 10 { history.removeLast(history.count - 10) }
        AgentTrace.record(text)
    }

    #if DEBUG
    /// 演示模式：直接设置展示字段，不启动调度器、感知与网络。
    func setDemo(phase: AgentPhase, plan: ShotPlan?, genreName: String?, rubric: RubricResult?,
                 report: TriggerReport?, crop: CameraCore.NormalizedRect?, subject: CameraCore.NormalizedRect?,
                 reason: String, faulted: Bool = false, tick: Bool = false) {
        demoLocked = true
        isEnabled = phase != .off
        self.phase = phase
        self.plan = plan
        isDefaultPlan = plan == nil
        self.genreName = genreName
        self.rubric = rubric
        rubricWeights = plan.flatMap { try? Knowledge.playbook($0.genre).rubricWeights } ?? [:]
        self.report = report
        self.crop = crop
        subjectBox = subject
        self.reason = reason
        self.faulted = faulted
        status = faulted ? "AI 需要检查密钥" : Self.statusText(phase)
        if tick { observationTick += 1; calls += 1 }
        if let plan, history.isEmpty { history = [AgentLogEntry(date: Date(), text: "新方案：\(genreName ?? "") · \(plan.rationale)")] }
    }
    #endif
}
