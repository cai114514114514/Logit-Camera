import Foundation

/// 生成字幕所需的 AI 状态快照。
public struct CaptionSnapshot: Sendable, Equatable {
    public var phase: AgentPhase
    public var isOffline: Bool
    public var genre: GenreID?
    public var genreName: String?
    public var isDefaultPlan: Bool
    public var planID: UUID?
    public var rationale: String?
    public var lens: LensStop?
    public var depth: DepthIntent?
    /// 还没达到、且数据可用的第一个时机信号。
    public var waitingFor: Trigger.Kind?
    public var starved: Bool
    /// 最近一次选片完成的时间（同一时间只算一次）。
    public var pickedAt: TimeInterval?
    /// AI 修正此刻最显著的一项（例如「压了压天空」）。
    public var correctionNote: String?

    public init(phase: AgentPhase, isOffline: Bool = false, genre: GenreID? = nil, genreName: String? = nil,
                isDefaultPlan: Bool = true, planID: UUID? = nil, rationale: String? = nil, lens: LensStop? = nil,
                depth: DepthIntent? = nil, waitingFor: Trigger.Kind? = nil, starved: Bool = false,
                pickedAt: TimeInterval? = nil, correctionNote: String? = nil) {
        self.phase = phase
        self.isOffline = isOffline
        self.genre = genre
        self.genreName = genreName
        self.isDefaultPlan = isDefaultPlan
        self.planID = planID
        self.rationale = rationale
        self.lens = lens
        self.depth = depth
        self.waitingFor = waitingFor
        self.starved = starved
        self.pickedAt = pickedAt
        self.correctionNote = correctionNote
    }
}

/// 字幕导演（规格 §2.4）：根据状态变化决定此刻说哪一句人话。
/// 一次一句、最多 16 字、2.5 秒后淡出、同一句 8 秒内不重复；高优先级可以打断低优先级。
public struct CaptionDirector: Sendable {
    public static let lifetime: TimeInterval = 2.5
    public static let repeatWindow: TimeInterval = 8
    public static let waitHold: TimeInterval = 1.5
    public static let maxLength = 16

    private var current: (text: String, priority: Int, until: TimeInterval)?
    private var shownAt: [String: TimeInterval] = [:]
    private var previous: CaptionSnapshot?
    private var waiting: (kind: Trigger.Kind, since: TimeInterval)?
    private var lastPicked: TimeInterval?

    public init() {}

    public mutating func update(_ s: CaptionSnapshot, now: TimeInterval) -> String? {
        defer { previous = s }
        guard s.phase != .off else {
            current = nil
            waiting = nil
            return nil
        }
        let before = previous
        var candidates: [(priority: Int, text: String)] = []

        if let picked = s.pickedAt, picked != lastPicked {
            lastPicked = picked
            candidates.append((100, s.genre == .portrait || s.genre == .group ? "挑了眼睛睁开的一张" : "挑了最清楚的一张"))
        }
        if s.phase == .capturing, before?.phase != .capturing {
            candidates.append((90, "就是现在"))
        }
        if let lens = s.lens, lens != before?.lens, before?.lens != nil || lens.zoomFactor != 1 {
            candidates.append((80, Self.lensPhrase(lens, depth: s.depth)))
        }
        if !s.isDefaultPlan, let id = s.planID, id != before?.planID, let rationale = s.rationale,
           let clause = Self.firstClause(rationale) {
            candidates.append((70, clause))
        }
        if s.isDefaultPlan, let genre = s.genre, genre != .general, genre != before?.genre, let name = s.genreName {
            candidates.append((60, "像是\(name)"))
        }
        if s.starved, before?.starved != true { candidates.append((50, "光线有点暗，拿稳一点")) }
        if let note = s.correctionNote, note != before?.correctionNote, [.planning, .composing].contains(s.phase) {
            candidates.append((45, note))
        }
        if s.isOffline, before?.isOffline != true { candidates.append((50, "没有网络，先按经验拍")) }
        if let kind = s.waitingFor, [.planning, .composing].contains(s.phase) {
            if waiting?.kind != kind { waiting = (kind, now) }
            if let since = waiting?.since, now - since >= Self.waitHold - 1e-9 {
                candidates.append((40, Self.waitPhrase(kind)))
            }
        } else {
            waiting = nil
        }
        if s.phase == .scouting, before?.phase != .scouting { candidates.append((30, "在看这是什么场景")) }
        if s.phase == .cooldown, before?.phase != .cooldown { candidates.append((20, "拍好了，换个场景继续")) }

        if let current, now >= current.until { self.current = nil }
        for candidate in candidates.sorted(by: { $0.priority > $1.priority }) {
            let text = Self.limit(candidate.text)
            if let last = shownAt[text], now - last < Self.repeatWindow { continue }
            if let current, candidate.priority < current.priority { break }
            self.current = (text, candidate.priority, now + Self.lifetime)
            shownAt[text] = now
            break
        }
        return current?.text
    }

    /// 「换到 2×，背景虚一点」。
    public static func lensPhrase(_ stop: LensStop, depth: DepthIntent?) -> String {
        let zoom = stop.zoomFactor == stop.zoomFactor.rounded() ? "\(Int(stop.zoomFactor))×" : "\(stop.zoomFactor)×"
        let reason: String? = switch stop.lens {
        case .ultraWide: "装下整个空间"
        case .telephoto: "拉近一点"
        case .wide: depth == .shallow ? "背景虚一点" : nil
        }
        return reason.map { "换到 \(zoom)，\($0)" } ?? "换到 \(zoom)"
    }

    /// 意图理由的第一个分句。
    public static func firstClause(_ text: String) -> String? {
        let clause = text.split(whereSeparator: { "，。；：,;:".contains($0) }).first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return clause.isEmpty ? nil : limit(clause)
    }

    public static func waitPhrase(_ kind: Trigger.Kind) -> String {
        switch kind {
        case .eyesOpen: "等眼睛睁开"
        case .faceToward: "等脸转过来"
        case .deviceStill: "拿稳一点"
        case .horizonLevel: "把手机放平"
        case .subjectSharp: "等对上焦"
        case .subjectPlaced: "等主体到位"
        case .highlightsSafe: "压一压高光"
        }
    }

    static func limit(_ text: String) -> String {
        text.count <= maxLength ? text : String(text.prefix(maxLength))
    }
}
