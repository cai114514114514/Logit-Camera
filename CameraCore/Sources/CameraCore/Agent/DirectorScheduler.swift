import Foundation

public enum AgentPhase: String, Codable, Sendable {
    case off, scouting, planning, composing, capturing, cooldown, paused
}

public struct ScoutResult: Codable, Equatable, Sendable {
    public var genre: GenreID
    public var confidence: Double
    public var sceneChanged: Bool
    public var planStillValid: Bool
    public var subjectHint: SubjectKind
    public var reason: String

    public init(genre: GenreID, confidence: Double, sceneChanged: Bool, planStillValid: Bool,
                subjectHint: SubjectKind, reason: String) {
        self.genre = genre
        self.confidence = confidence
        self.sceneChanged = sceneChanged
        self.planStillValid = planStillValid
        self.subjectHint = subjectHint
        self.reason = reason
    }
}

public enum DirectorReply: Equatable, Sendable {
    case plan(ShotPlan, RubricResult?)
    /// 方案未通过校验；文字原样反馈给下一次导演请求。
    case invalid(String)
}

public enum SchedulerEvent: Sendable {
    case start, stop, pause, resume
    case measurement(SceneMeasurement, MomentReport)
    case scoutReply(id: Int, ScoutResult)
    case directorReply(id: Int, DirectorReply)
    /// `stale`：回复因画面已变化而被丢弃，不计入失败、不加长退避。
    case requestFailed(id: Int, retryable: Bool, stale: Bool)
    /// 照片已拍下（自动或手动）。
    case captured
    /// 触发拍摄时相机拒绝。
    case fireRejected
    /// 冷却中「再拍一张」。
    case rearm
}

public enum SchedulerCommand: Equatable, Sendable {
    case none, callScout, callDirector(GenreID, feedback: String?), fire
}

public struct SchedulerOutput: Equatable, Sendable {
    public var command: SchedulerCommand = .none
    /// 请求编号；回复必须带回同一个编号才会被采纳。
    public var requestID: Int?
    /// 感知层应以当前帧作为新的场景变化基线。
    public var resetBaseline = false
    /// 导演的对话记忆应清空（场景或题材变化）。
    public var resetMemory = false
    /// 时机评分重新计时（新方案、离线回退、再拍一张、恢复）。
    public var restartMoment = false

    public init() {}
}

/// Agent 的调度状态机（规格 §7.2）：纯函数式，输入事件与时间，输出「调哪一档 / 是否拍摄」。
/// 导演只给意图，没有放行权；时机由本机的 MomentScorer 决定。
public struct DirectorScheduler: Sendable {
    public static let sceneChangeThreshold = 0.18
    public static let sceneChangeHold: TimeInterval = 0.5
    public static let subjectLostHold: TimeInterval = 1
    public static let heartbeat: TimeInterval = 15
    public static let scoutSpacing: TimeInterval = 2
    public static let directorSpacing: TimeInterval = 4
    public static let offlineFallback: TimeInterval = 3
    public static let backoff: [TimeInterval] = [5, 10, 20, 30]
    public static let maxInvalidRetries = 1

    public private(set) var phase: AgentPhase = .off
    public private(set) var plan: ShotPlan?
    public private(set) var isDefaultPlan = false
    /// 侦察一直没有成功：用通用默认意图在本机取景。
    public private(set) var isOffline = false
    public private(set) var inFlightID: Int?

    private let defaultPlan: @Sendable (GenreID) -> ShotPlan
    /// 单调递增，跨 start / stop 不重置。
    private var lastRequestID = 0
    private var startedAt: TimeInterval = 0
    private var scoutSucceeded = false
    private var lastScoutAt: TimeInterval?
    private var lastDirectorAt: TimeInterval?
    private var lastCallAt: TimeInterval?
    private var sceneChangeSince: TimeInterval?
    private var subjectLostSince: TimeInterval?
    private var pendingGenre: GenreID?
    private var feedback: String?
    private var invalidCount = 0
    private var directorBlocked = false
    private var failures = 0
    private var backoffUntil: TimeInterval = 0
    private var pausedFrom: AgentPhase?

    public init(defaultPlan: @escaping @Sendable (GenreID) -> ShotPlan) {
        self.defaultPlan = defaultPlan
    }

    /// 使用随包知识库的调度器。
    public static func live() throws -> DirectorScheduler {
        let playbooks = Dictionary(uniqueKeysWithValues: try Knowledge.allPlaybooks().map { ($0.id, $0) })
        guard let general = playbooks[.general] else { throw KnowledgeError.missing("general") }
        return DirectorScheduler(defaultPlan: { genre in
            var plan = playbooks[genre]?.defaultPlan ?? general.defaultPlan
            plan.id = UUID()
            return plan
        })
    }

    public var isActive: Bool { ![.off, .paused].contains(phase) }

    public mutating func handle(_ event: SchedulerEvent, now: TimeInterval) -> SchedulerOutput {
        switch event {
        case .start:
            resetTimers()
            plan = defaultPlan(.general)
            isDefaultPlan = true
            isOffline = false
            phase = .scouting
            startedAt = now
            scoutSucceeded = false
            failures = 0
            backoffUntil = 0
            invalidCount = 0
            directorBlocked = false
            feedback = nil
            pendingGenre = nil
            var out = SchedulerOutput()
            out.resetBaseline = true
            out.resetMemory = true
            out.restartMoment = true
            call(.callScout, now: now, into: &out)
            return out
        case .stop:
            phase = .off
            plan = nil
            isDefaultPlan = false
            isOffline = false
            inFlightID = nil
            pendingGenre = nil
            return SchedulerOutput()
        case .pause:
            guard isActive else { return SchedulerOutput() }
            pausedFrom = phase
            phase = .paused
            inFlightID = nil
            return SchedulerOutput()
        case .resume:
            guard phase == .paused else { return SchedulerOutput() }
            switch pausedFrom {
            case .cooldown?: phase = .cooldown
            case .scouting?: phase = .scouting
            default: phase = pendingGenre == nil ? .composing : .planning
            }
            resetTimers(keepCalls: true)
            var out = SchedulerOutput()
            out.resetBaseline = true
            out.restartMoment = true
            return out
        case .measurement(let m, let report):
            return measure(m, report, now: now)
        case .scoutReply(let id, let result):
            guard accept(id) else { return SchedulerOutput() }
            failures = 0
            return scouted(result, now: now)
        case .directorReply(let id, let reply):
            guard accept(id) else { return SchedulerOutput() }
            failures = 0
            return directed(reply)
        case .requestFailed(let id, let retryable, let stale):
            guard accept(id) else { return SchedulerOutput() }
            guard retryable else { return handle(.stop, now: now) }
            if !stale {
                failures = min(failures + 1, Self.backoff.count)
                backoffUntil = now + Self.backoff[failures - 1]
            }
            return SchedulerOutput()
        case .captured:
            guard [.scouting, .planning, .composing, .capturing, .cooldown].contains(phase) else { return SchedulerOutput() }
            phase = .cooldown
            sceneChangeSince = nil
            var out = SchedulerOutput()
            out.resetBaseline = true
            return out
        case .fireRejected:
            guard phase == .capturing else { return SchedulerOutput() }
            phase = workingPhase
            return SchedulerOutput()
        case .rearm:
            guard phase == .cooldown else { return SchedulerOutput() }
            phase = workingPhase
            var out = SchedulerOutput()
            out.restartMoment = true
            return out
        }
    }

    // MARK: - Events

    /// 有待定方案时为 planning，否则 composing。
    private var workingPhase: AgentPhase { pendingGenre == nil ? .composing : .planning }

    private mutating func accept(_ id: Int) -> Bool {
        guard isActive, let inFlightID, id == inFlightID else { return false }
        self.inFlightID = nil
        return true
    }

    private mutating func measure(_ m: SceneMeasurement, _ report: MomentReport, now: TimeInterval) -> SchedulerOutput {
        guard [.scouting, .planning, .composing, .cooldown].contains(phase) else { return SchedulerOutput() }
        var out = SchedulerOutput()
        sceneChangeSince = m.sceneChange > Self.sceneChangeThreshold ? (sceneChangeSince ?? now) : nil
        let wantsSubject = (plan?.subject ?? .none) != .none
        subjectLostSince = wantsSubject && m.primarySubject == nil ? (subjectLostSince ?? now) : nil

        if phase == .scouting, !scoutSucceeded, now - startedAt >= Self.offlineFallback - 1e-9 {
            phase = .composing
            isOffline = true
            out.restartMoment = true
        }

        if [.planning, .composing].contains(phase), report.fireReady {
            phase = .capturing
            out.command = .fire
            return out
        }

        let sceneMoved = held(sceneChangeSince, Self.sceneChangeHold, now)
        if phase == .cooldown {
            guard sceneMoved else { return out }
            phase = .scouting
            startedAt = now
            scoutSucceeded = false
            out.resetBaseline = true
            out.resetMemory = true
        }

        guard inFlightID == nil, now >= backoffUntil else { return out }

        let subjectLost = held(subjectLostSince, Self.subjectLostHold, now)
        let quiet = now - (lastCallAt ?? startedAt) >= Self.heartbeat - 1e-9
        if phase == .scouting || sceneMoved || subjectLost || quiet {
            if spaced(lastScoutAt, Self.scoutSpacing, now) { call(.callScout, now: now, into: &out) }
            return out
        }
        if let genre = pendingGenre, !directorBlocked, spaced(lastDirectorAt, Self.directorSpacing, now) {
            call(.callDirector(genre, feedback: feedback), now: now, into: &out)
        }
        return out
    }

    private mutating func scouted(_ result: ScoutResult, now: TimeInterval) -> SchedulerOutput {
        var out = SchedulerOutput()
        let wasOffline = isOffline
        scoutSucceeded = true
        isOffline = false
        var needsPlan = isDefaultPlan || !result.planStillValid || result.sceneChanged || result.genre != plan?.genre
        // 导演连续给出无效方案后，同一题材、场景未变时保持默认意图，不再反复请求。
        if directorBlocked, result.genre == plan?.genre, !result.sceneChanged { needsPlan = false }
        // 已在执行该题材的默认方案、导演请求待发：不重复替换。
        if needsPlan, isDefaultPlan, pendingGenre == result.genre, plan?.genre == result.genre, !result.sceneChanged {
            needsPlan = false
        }

        guard needsPlan else {
            if phase == .scouting || phase == .planning && pendingGenre == nil { phase = workingPhase }
            sceneChangeSince = nil
            subjectLostSince = nil
            out.resetBaseline = true
            out.restartMoment = wasOffline
            return out
        }
        plan = defaultPlan(result.genre)
        isDefaultPlan = true
        pendingGenre = result.genre
        invalidCount = 0
        directorBlocked = false
        feedback = nil
        sceneChangeSince = nil
        subjectLostSince = nil
        if [.scouting, .planning, .composing].contains(phase) { phase = .planning }
        out.resetBaseline = true
        out.resetMemory = true
        out.restartMoment = true
        if spaced(lastDirectorAt, Self.directorSpacing, now) {
            call(.callDirector(result.genre, feedback: nil), now: now, into: &out)
        }
        return out
    }

    private mutating func directed(_ reply: DirectorReply) -> SchedulerOutput {
        var out = SchedulerOutput()
        switch reply {
        case .plan(let newPlan, _):
            plan = newPlan
            isDefaultPlan = false
            pendingGenre = nil
            invalidCount = 0
            feedback = nil
            if phase == .planning { phase = .composing }
            out.resetBaseline = true
            out.restartMoment = phase == .composing
        case .invalid(let detail):
            invalidCount += 1
            if invalidCount <= Self.maxInvalidRetries {
                feedback = detail
            } else {
                directorBlocked = true
                pendingGenre = nil
                feedback = nil
                if phase == .planning { phase = .composing }
            }
        }
        return out
    }

    // MARK: - Helpers

    private mutating func call(_ command: SchedulerCommand, now: TimeInterval, into out: inout SchedulerOutput) {
        lastRequestID += 1
        inFlightID = lastRequestID
        lastCallAt = now
        switch command {
        case .callScout: lastScoutAt = now
        case .callDirector: lastDirectorAt = now
        default: break
        }
        out.command = command
        out.requestID = lastRequestID
    }

    private mutating func resetTimers(keepCalls: Bool = false) {
        sceneChangeSince = nil
        subjectLostSince = nil
        if !keepCalls {
            lastScoutAt = nil
            lastDirectorAt = nil
            lastCallAt = nil
        }
    }

    private func held(_ since: TimeInterval?, _ duration: TimeInterval, _ now: TimeInterval) -> Bool {
        guard let since else { return false }
        return now - since >= duration - 1e-9
    }

    private func spaced(_ last: TimeInterval?, _ spacing: TimeInterval, _ now: TimeInterval) -> Bool {
        guard let last else { return true }
        return now - last >= spacing - 1e-9
    }
}
