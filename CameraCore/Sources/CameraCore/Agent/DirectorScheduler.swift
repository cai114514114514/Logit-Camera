import Foundation

public enum AgentPhase: String, Codable, Sendable {
    case off, scouting, planning, tracking, reviewing, armed, capturing, cooldown, paused
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

public enum JudgeResult: Equatable, Sendable {
    case setPlan(ShotPlan, RubricResult)
    case keepPlan(RubricResult, reason: String)
}

public enum JudgeMode: Equatable, Sendable {
    /// 为该题材制定（或替换）方案。
    case plan(GenreID)
    /// 方案不变，请求对当前画面评分与放行。
    case approve
}

public enum SchedulerEvent: Sendable {
    case start, stop, pause, resume
    case measurement(SceneMeasurement, TriggerReport)
    case scoutReply(generation: Int, ScoutResult)
    case judgeReply(generation: Int, JudgeResult)
    case requestFailed(generation: Int, retryable: Bool)
    case captured, rearm
}

public enum SchedulerCommand: Equatable, Sendable {
    case none, callScout, callJudge(JudgeMode), fire
}

public struct SchedulerOutput: Equatable, Sendable {
    public var command: SchedulerCommand = .none
    /// 感知层应以当前帧作为新的场景变化基线（新方案、放行、拍摄之后）。
    public var resetBaseline = false
    /// 评审的对话记忆应清空（场景或题材变化）。
    public var resetMemory = false
}

/// Agent 的调度状态机：纯函数式，输入事件与时间，输出「调哪一档 / 是否拍摄」。
/// 所有阈值见规格 §7.2。模型回复携带 generation，过期的回复被忽略。
public struct DirectorScheduler: Sendable {
    public static let sceneChangeThreshold = 0.18
    public static let sceneChangeHold: TimeInterval = 0.5
    public static let subjectLostHold: TimeInterval = 1
    public static let heartbeat: TimeInterval = 15
    public static let scoutSpacing: TimeInterval = 2
    public static let judgeSpacing: TimeInterval = 4
    public static let approvalLifetime: TimeInterval = 10
    public static let approvalDrift = 0.08
    public static let nearlyReadyHold: TimeInterval = 0.5
    public static let backoff: [TimeInterval] = [5, 10, 20, 30]

    public private(set) var phase: AgentPhase = .off
    public private(set) var plan: ShotPlan?
    public private(set) var isDefaultPlan = false
    public private(set) var generation = 0
    public private(set) var inFlight = false

    private let weights: @Sendable (GenreID) -> [RubricCriterion: Double]
    private let defaultPlan: @Sendable (GenreID) -> ShotPlan
    private var lastScoutAt: TimeInterval?
    private var lastJudgeAt: TimeInterval?
    private var lastCallAt: TimeInterval?
    private var sceneChangeSince: TimeInterval?
    private var subjectLostSince: TimeInterval?
    private var nearlyReadySince: TimeInterval?
    private var approvedAt: TimeInterval?
    private var pendingPlan: GenreID?
    private var failures = 0
    private var backoffUntil: TimeInterval = 0
    private var pausedFrom: AgentPhase?

    public init(weights: @escaping @Sendable (GenreID) -> [RubricCriterion: Double],
                defaultPlan: @escaping @Sendable (GenreID) -> ShotPlan) {
        self.weights = weights
        self.defaultPlan = defaultPlan
    }

    /// 使用随包知识库的调度器。
    public static func live() throws -> DirectorScheduler {
        let playbooks = Dictionary(uniqueKeysWithValues: try Knowledge.allPlaybooks().map { ($0.id, $0) })
        guard let general = playbooks[.general] else { throw KnowledgeError.missing("general") }
        return DirectorScheduler(weights: { playbooks[$0]?.rubricWeights ?? general.rubricWeights },
                                 defaultPlan: { playbooks[$0]?.defaultPlan ?? general.defaultPlan })
    }

    public mutating func handle(_ event: SchedulerEvent, now: TimeInterval) -> SchedulerOutput {
        switch event {
        case .start:
            resetTimers()
            generation += 1
            plan = defaultPlan(.general)
            isDefaultPlan = true
            phase = .scouting
            failures = 0
            backoffUntil = 0
            var out = SchedulerOutput(resetBaseline: true, resetMemory: true)
            out.command = call(.callScout, now: now)
            return out
        case .stop:
            generation += 1
            phase = .off
            plan = nil
            isDefaultPlan = false
            inFlight = false
            pendingPlan = nil
            return SchedulerOutput()
        case .pause:
            guard phase != .off, phase != .paused else { return SchedulerOutput() }
            pausedFrom = phase
            phase = .paused
            generation += 1
            inFlight = false
            return SchedulerOutput()
        case .resume:
            guard phase == .paused else { return SchedulerOutput() }
            phase = isDefaultPlan ? .scouting : (pausedFrom == .cooldown ? .cooldown : .tracking)
            if phase == .tracking, pendingPlan == nil, pausedFrom == .planning, let genre = plan?.genre {
                pendingPlan = genre
            }
            resetTimers(keepCalls: true)
            return SchedulerOutput(resetBaseline: true)
        case .measurement(let m, let report):
            return measure(m, report, now: now)
        case .scoutReply(let replyGeneration, let result):
            guard replyGeneration == generation, inFlight else { return SchedulerOutput() }
            inFlight = false
            failures = 0
            return scouted(result, now: now)
        case .judgeReply(let replyGeneration, let result):
            guard replyGeneration == generation, inFlight else { return SchedulerOutput() }
            inFlight = false
            failures = 0
            return judged(result, now: now)
        case .requestFailed(let replyGeneration, let retryable):
            guard replyGeneration == generation, inFlight else { return SchedulerOutput() }
            inFlight = false
            guard retryable else { return handle(.stop, now: now) }
            failures = min(failures + 1, Self.backoff.count)
            backoffUntil = now + Self.backoff[failures - 1]
            if phase == .reviewing { phase = .tracking }
            return SchedulerOutput()
        case .captured:
            guard phase == .capturing else { return SchedulerOutput() }
            phase = .cooldown
            sceneChangeSince = nil
            approvedAt = nil
            return SchedulerOutput(resetBaseline: true)
        case .rearm:
            guard phase == .cooldown else { return SchedulerOutput() }
            phase = .tracking
            nearlyReadySince = nil
            return SchedulerOutput()
        }
    }

    // MARK: - Events

    private mutating func measure(_ m: SceneMeasurement, _ report: TriggerReport, now: TimeInterval) -> SchedulerOutput {
        guard [.scouting, .planning, .tracking, .reviewing, .armed, .cooldown].contains(phase) else {
            return SchedulerOutput()
        }
        sceneChangeSince = m.sceneChange > Self.sceneChangeThreshold ? (sceneChangeSince ?? now) : nil
        let wantsSubject = !isDefaultPlan && (plan?.subject ?? .none) != .none
        subjectLostSince = wantsSubject && m.primarySubject == nil ? (subjectLostSince ?? now) : nil
        nearlyReadySince = report.nearlyReady ? (nearlyReadySince ?? now) : nil
        var out = SchedulerOutput()

        if phase == .armed {
            let expired = now - (approvedAt ?? now) > Self.approvalLifetime
            if expired || m.sceneChange > Self.approvalDrift {
                phase = .tracking
                approvedAt = nil
                nearlyReadySince = nil
            } else if report.sustained {
                phase = .capturing
                out.command = .fire
                return out
            } else {
                return out
            }
        }

        if phase == .cooldown {
            guard held(sceneChangeSince, Self.sceneChangeHold, now) else { return out }
            phase = .scouting
            out.resetBaseline = true
            out.resetMemory = true
        }

        guard !inFlight, now >= backoffUntil else { return out }

        let sceneMoved = held(sceneChangeSince, Self.sceneChangeHold, now)
        let subjectLost = held(subjectLostSince, Self.subjectLostHold, now)
        let quiet = now - (lastCallAt ?? now) >= Self.heartbeat
        if phase == .scouting || sceneMoved || subjectLost || quiet {
            if spaced(lastScoutAt, Self.scoutSpacing, now) { out.command = call(.callScout, now: now) }
            return out
        }
        if let genre = pendingPlan, spaced(lastJudgeAt, Self.judgeSpacing, now) {
            out.command = call(.callJudge(.plan(genre)), now: now)
            return out
        }
        if phase == .tracking, !isDefaultPlan, held(nearlyReadySince, Self.nearlyReadyHold, now),
           spaced(lastJudgeAt, Self.judgeSpacing, now) {
            phase = .reviewing
            out.command = call(.callJudge(.approve), now: now)
        }
        return out
    }

    private mutating func scouted(_ result: ScoutResult, now: TimeInterval) -> SchedulerOutput {
        var out = SchedulerOutput()
        let needsPlan = isDefaultPlan || !result.planStillValid || result.sceneChanged || result.genre != plan?.genre
        guard needsPlan else {
            if phase == .scouting { phase = .tracking }
            return out
        }
        phase = .planning
        pendingPlan = result.genre
        approvedAt = nil
        out.resetMemory = true
        out.resetBaseline = true
        if spaced(lastJudgeAt, Self.judgeSpacing, now) {
            out.command = call(.callJudge(.plan(result.genre)), now: now)
        }
        return out
    }

    private mutating func judged(_ result: JudgeResult, now: TimeInterval) -> SchedulerOutput {
        var out = SchedulerOutput()
        nearlyReadySince = nil
        let rubric: RubricResult
        switch result {
        case .setPlan(let newPlan, let score):
            plan = newPlan
            isDefaultPlan = false
            pendingPlan = nil
            rubric = score
            out.resetBaseline = true
        case .keepPlan(let score, _):
            rubric = score
        }
        guard let genre = plan?.genre else { return out }
        switch rubric.verdict(weights: weights(genre)) {
        case .approve where !isDefaultPlan:
            phase = .armed
            approvedAt = now
            out.resetBaseline = true
        case .revise:
            phase = .planning
            pendingPlan = genre
        default:
            phase = .tracking
        }
        return out
    }

    // MARK: - Helpers

    private mutating func call(_ command: SchedulerCommand, now: TimeInterval) -> SchedulerCommand {
        inFlight = true
        lastCallAt = now
        switch command {
        case .callScout: lastScoutAt = now
        case .callJudge: lastJudgeAt = now
        default: break
        }
        return command
    }

    private mutating func resetTimers(keepCalls: Bool = false) {
        sceneChangeSince = nil
        subjectLostSince = nil
        nearlyReadySince = nil
        approvedAt = nil
        if !keepCalls {
            lastScoutAt = nil
            lastJudgeAt = nil
            lastCallAt = nil
            pendingPlan = nil
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
