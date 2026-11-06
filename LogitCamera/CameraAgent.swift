import CameraCore
import Foundation
import Observation

enum AgentStage: String, Sendable {
    case observing, thinking, applying, verifying, ready, countdown, paused
}

@MainActor @Observable
final class CameraAgent {
    var isEnabled = false
    var isBusy = false
    var status = "AI 待命"
    var reason = ""
    var round = 0
    var stage: AgentStage = .paused
    var countdown: Int?
    var autoCaptureEnabled = true
    var captureArmed = true
    var confirmationCount = 0
    var changes: [ParameterDelta] = []
    /// 每次真正截取一帧准备发给模型时自增，驱动取景扫描线。
    var observationTick = 0
    /// 每次调整在硬件回读后换新值，驱动 AI 标注。
    var adjustmentID: UUID?
    /// 调整成功后通知模型，用于标记参数由 AI 设定。
    @ObservationIgnored var onAdjusted: (() -> Void)?
    /// 演示模式下禁止启动真实循环。
    @ObservationIgnored var demoLocked = false
    @ObservationIgnored var onAutoCapture: (() -> Bool)?
    @ObservationIgnored private var readiness = CaptureReadiness()
    @ObservationIgnored private var confirmedFrame: CameraFrame?
    @ObservationIgnored private var countdownAttempt: UUID?
    let modelName = AICredentials.displayName
    @ObservationIgnored private let client = DeepSeekClient()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation: UUID?
    @ObservationIgnored private var capture: CaptureSession?
    @ObservationIgnored private var previous: AgentExchange?

    func enable(capture: CaptureSession, key: String) {
        isEnabled = true
        round = 0
        previous = nil
        captureArmed = true
        resetReadiness()
        resume(capture: capture, key: key)
    }

    func resume(capture: CaptureSession, key: String) {
        guard isEnabled, task == nil, !demoLocked else { return }
        let token = UUID()
        generation = token
        self.capture = capture
        capture.beginAgent(token)
        task = Task { [weak self] in
            await self?.run(capture: capture, key: key, token: token)
        }
    }

    func pause() {
        generation = nil
        task?.cancel()
        task = nil
        capture?.cancelAgent()
        isBusy = false
        countdown = nil
        countdownAttempt = nil
        stage = .paused
        resetReadiness()
        if isEnabled { status = "AI 暂停" }
    }

    func stop() {
        isEnabled = false
        pause()
        status = "AI 待命"
        reason = ""
    }

    func setAutoCapture(_ enabled: Bool) {
        autoCaptureEnabled = enabled
        countdown = nil
        countdownAttempt = nil
        if isEnabled { stage = .observing }
        resetReadiness()
    }

    func armAutoCapture() {
        captureArmed = true
        countdown = nil
        countdownAttempt = nil
        resetReadiness()
        status = "等待重新确认"
    }

    func cancelAutoCapture() {
        captureArmed = false
        countdown = nil
        countdownAttempt = nil
        resetReadiness()
        stage = .observing
        status = "自动快门已暂停"
    }

    private func resetReadiness() {
        readiness.reset()
        confirmationCount = 0
        confirmedFrame = nil
    }

    private func run(capture: CaptureSession, key: String, token: UUID) async {
        var failures = 0
        while isCurrent(token) {
            do {
                isBusy = true
                status = "观察画面"
                stage = .observing
                let observation = try await capture.observation()
                try checkCurrent(token)
                observationTick += 1
                status = "AI 分析中"
                stage = .thinking
                let reply = try await client.decide(observation: observation, previous: previous, key: key)
                try checkCurrent(token)
                round += 1
                let fresh = try await capture.observation()
                try checkCurrent(token)
                let age = ProcessInfo.processInfo.systemUptime - observation.frame.timestamp
                AgentTrace.record(round: round, age: age, difference: fresh.frame.difference(from: observation.frame),
                                  action: reply.decision.action.rawValue, outcome: "response", requested: reply.decision.settings, actual: fresh.context.actual)
                guard age <= 12, fresh.frame.difference(from: observation.frame) < 0.18 else {
                    previous = AgentExchange(call: reply.call, outcome: "未执行：画面已变化或观察过期。下一轮依据新的画面重新决定。")
                    throw AIError.staleScene
                }
                reason = reply.decision.reason
                if reply.decision.action == .adjust, let settings = reply.decision.settings {
                    resetReadiness()
                    if differs(settings, from: fresh.context) {
                        status = "正在调整相机"
                        stage = .applying
                        do {
                            try await capture.apply(settings, token: token)
                            try checkCurrent(token)
                            try await Task.sleep(for: .milliseconds(450))
                            let result = try await capture.observation()
                            try checkCurrent(token)
                            previous = AgentExchange(call: reply.call, outcome: feedback("已执行", observation: result))
                            changes = parameterChanges(from: fresh.context, to: result.context)
                            adjustmentID = UUID()
                            onAdjusted?()
                            AgentTrace.record(round: round, age: age, difference: 0, action: "adjust",
                                              outcome: "applied", requested: settings, actual: result.context.actual)
                            status = "已调整 · 等待复核"
                            stage = .verifying
                        } catch is CancellationError { throw CancellationError() }
                        catch {
                            previous = AgentExchange(call: reply.call, outcome: "设备拒绝执行：" + error.localizedDescription)
                            throw error
                        }
                    } else {
                        previous = AgentExchange(call: reply.call, outcome: feedback("设置已接近目标，保持以避免抖动", observation: fresh))
                        status = "保持当前构图"
                        stage = .verifying
                    }
                } else {
                    previous = AgentExchange(call: reply.call, outcome: feedback("已保持当前设置", observation: fresh))
                    status = "保持当前构图"
                    stage = .verifying
                    let stable = fresh.frame.difference(from: observation.frame) < 0.05
                        && (confirmedFrame.map { fresh.frame.difference(from: $0) < 0.05 } ?? true)
                    let hardwareReady = !fresh.context.actual.adjustingExposure && !fresh.context.actual.adjustingFocus
                    let ready = readiness.observe(confirmed: reply.decision.readyToCapture, stable: stable, hardwareReady: hardwareReady)
                    confirmationCount = readiness.confirmations
                    confirmedFrame = confirmationCount > 0 ? fresh.frame : nil
                    if confirmationCount > 0 {
                        stage = .ready
                        status = "准备拍摄 · \(confirmationCount)/2 次确认"
                    }
                    if ready, autoCaptureEnabled, captureArmed {
                        isBusy = false
                        if try await countDown(capture: capture, baseline: fresh, token: token) { break }
                    }
                }
                failures = 0
                isBusy = false
                // A single task owns the entire loop: no overlapping API requests.
                try await Task.sleep(for: .seconds(5))
            } catch is CancellationError { break }
            catch {
                guard isCurrent(token) else { break }
                isBusy = false
                resetReadiness()
                if case AIError.authentication = error {
                    stop()
                    status = "AI 需要检查密钥"
                    reason = error.localizedDescription
                    break
                }
                if case AIError.staleScene = error {
                    status = "画面变化 · 重新观察"
                    reason = "上一轮建议已丢弃，没有改变相机参数。"
                } else {
                    failures = min(failures + 1, 6)
                    status = "AI 暂时无法调整"
                    reason = error.localizedDescription
                }
                do { try await Task.sleep(for: .seconds(failures == 0 ? 5 : Double(failures * 5))) }
                catch { break }
            }
        }
        // An older cancelled task must never clear a newly started loop.
        if generation == token {
            task = nil
            isBusy = false
        }
    }

    private func checkCurrent(_ token: UUID) throws {
        try Task.checkCancellation()
        guard isCurrent(token) else { throw CancellationError() }
    }

    private func isCurrent(_ token: UUID) -> Bool { isEnabled && generation == token }

    private func countDown(capture: CaptureSession, baseline: CameraObservation, token: UUID) async throws -> Bool {
        let attempt = UUID()
        countdownAttempt = attempt
        defer {
            if countdownAttempt == attempt {
                countdown = nil
                countdownAttempt = nil
            }
        }
        stage = .countdown
        for number in [3, 2, 1] {
            guard validCountdown(attempt, token: token) else { return false }
            countdown = number
            status = "保持稳定 · \(number) 秒后拍照"
            try await Task.sleep(for: .seconds(1))
            try checkCurrent(token)
            guard validCountdown(attempt, token: token) else { return false }
            let fresh = try await capture.observation()
            try checkCurrent(token)
            guard validCountdown(attempt, token: token) else { return false }
            guard fresh.frame.difference(from: baseline.frame) < 0.05,
                  !fresh.context.actual.adjustingFocus, !fresh.context.actual.adjustingExposure,
                  !differs(baseline.context.settings, from: fresh.context) else {
                resetReadiness()
                stage = .observing
                status = "画面或参数变化 · 重新确认"
                return false
            }
        }
        guard validCountdown(attempt, token: token) else { return false }
        captureArmed = false
        status = "正在拍照"
        if onAutoCapture?() == true { return true }
        captureArmed = true
        resetReadiness()
        status = "相机暂未就绪 · 重新确认"
        return false
    }

    private func validCountdown(_ attempt: UUID, token: UUID) -> Bool {
        isCurrent(token) && countdownAttempt == attempt && autoCaptureEnabled && captureArmed
    }

    private func parameterChanges(from before: ObservationContext, to after: ObservationContext) -> [ParameterDelta] {
        ParameterDelta.changed([
            ParameterDelta(id: "aperture", title: "光圈", before: CameraText.aperture(Float(before.actual.aperture)), after: CameraText.aperture(Float(after.actual.aperture))),
            ParameterDelta(id: "iso", title: "ISO", before: String(Int(before.actual.iso)), after: String(Int(after.actual.iso))),
            ParameterDelta(id: "shutter", title: "快门", before: CameraText.shutter(before.actual.shutterSeconds), after: CameraText.shutter(after.actual.shutterSeconds)),
            ParameterDelta(id: "bias", title: "曝光", before: CameraText.bias(Float(before.actual.exposureBias)), after: CameraText.bias(Float(after.actual.exposureBias))),
            ParameterDelta(id: "ratio", title: "画幅", before: before.settings.ratio.rawValue, after: after.settings.ratio.rawValue),
            ParameterDelta(id: "zoom", title: "变焦", before: CameraText.zoom(Float(before.actual.zoom)), after: CameraText.zoom(Float(after.actual.zoom)))
        ])
    }

    private func feedback(_ outcome: String, observation: CameraObservation) -> String {
        let data = (try? JSONEncoder().encode(observation.context)) ?? Data()
        return outcome + "；设备实际读数和设置：" + String(decoding: data, as: UTF8.self)
    }

    private func differs(_ desired: CameraSettings, from current: ObservationContext) -> Bool {
        // Requested targets are not proof of execution, especially after timeout.
        // Compare the device's actual mode and values instead.
        let actual = current.actual
        if (desired.aperture == nil) != actual.apertureAuto
            || (desired.iso == nil) != actual.isoAuto
            || (desired.shutterSeconds == nil) != actual.shutterAuto { return true }
        if let aperture = desired.aperture, abs(aperture - actual.aperture) > 0.08 { return true }
        if let iso = desired.iso, abs(iso - actual.iso) > max(10, iso * 0.1) { return true }
        if let shutter = desired.shutterSeconds, abs(shutter - actual.shutterSeconds) > max(0.0001, shutter * 0.1) { return true }
        return desired.ratio != current.settings.ratio
            || abs(desired.zoom - actual.zoom) > 0.03
            || abs(desired.exposureBias - actual.exposureBias) > 0.15
    }
}
