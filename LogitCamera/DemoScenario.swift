#if DEBUG
import CameraCore
import Foundation

/// 仅调试版：`-LogitDemo <scenario>` 直接展示某个 AI 状态，用于不消耗 API 额度的界面截图。
/// 演示期间 `AgentController.demoLocked` 阻止真实的调度器、感知与网络请求。
enum DemoScenario: String, CaseIterable {
    case idle, scouting, composing, capturing, cooldown, landscape, manual, error, offline

    static var current: DemoScenario? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-LogitDemo"), index + 1 < arguments.count else { return nil }
        return DemoScenario(rawValue: arguments[index + 1])
    }
}

extension CameraModel {
    func applyDemo(_ scenario: DemoScenario) {
        let agent = self.agent
        agent.demoLocked = true
        let subject = CameraCore.NormalizedRect(x: 0.52, y: 0.28, width: 0.2, height: 0.16)
        let portrait = demoPlan(.portrait, rationale: "逆光人像：脸朝左，主体放右三分，保住发丝高光")
        let landscape = demoPlan(.landscape, ratio: .square, rationale: "方形裁掉底部暗水面，等云影打亮崖壁")

        let portraitLens = LensStop(focalLength: 48, zoomFactor: 2, lens: .wide)
        let landscapeLens = LensStop(focalLength: 24, zoomFactor: 1, lens: .wide)

        switch scenario {
        case .idle:
            break
        case .scouting:
            Task { @MainActor in
                while true {
                    agent.setDemo(phase: .scouting, plan: nil, genreName: nil, critique: nil, moment: nil, crop: nil,
                                  subject: subject, reason: "", tick: true)
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        case .composing:
            agentOwnsSettings = true
            agent.setDemo(phase: .composing, plan: portrait, genreName: "人像", critique: demoRubric(2, light: 3, moment: 2),
                          moment: demoMoment(portrait, eyes: 0.3), crop: demoCrop(portrait, subject), subject: subject,
                          lens: portraitLens, reason: "等她睁眼看向镜头", tick: true)
        case .capturing:
            agentOwnsSettings = true
            agent.setDemo(phase: .capturing, plan: portrait, genreName: "人像", critique: demoRubric(3, light: 4, moment: 3),
                          moment: demoMoment(portrait, eyes: 0.9), crop: demoCrop(portrait, subject),
                          subject: subject, lens: portraitLens, reason: "光线与神情都到位")
        case .cooldown:
            agent.setDemo(phase: .cooldown, plan: portrait, genreName: "人像", critique: demoRubric(3, light: 4, moment: 4),
                          moment: demoMoment(portrait, eyes: 0.9), crop: demoCrop(portrait, subject), subject: subject,
                          lens: portraitLens, reason: "已拍摄")
        case .landscape:
            agentOwnsSettings = true
            agent.setDemo(phase: .composing, plan: landscape, genreName: "风光", critique: demoRubric(2, light: 2, moment: 2),
                          moment: demoMoment(landscape, eyes: nil), crop: demoCrop(landscape, nil), subject: nil,
                          lens: landscapeLens, reason: "等云影或低角度暖光打亮崖壁")
        case .manual:
            post("你接管了光圈 · AI 已停止", offersResume: true, sticky: true)
        case .error:
            agent.setDemo(phase: .off, plan: nil, genreName: nil, critique: nil, moment: nil, crop: nil, subject: nil,
                          reason: "密钥无效或账户额度不足，请检查 AI 设置。", faulted: true)
        case .offline:
            agentOwnsSettings = true
            let general = demoPlan(.general, rationale: "通用默认意图")
            agent.setDemo(phase: .composing, plan: general, genreName: "通用", critique: nil,
                          moment: demoMoment(general, eyes: nil), crop: demoCrop(general, nil), subject: nil,
                          lens: landscapeLens, reason: "网络不可用，按通用意图在本机取景", offline: true)
        }
    }

    private func demoPlan(_ genre: GenreID, ratio: FrameRatio? = nil, rationale: String) -> ShotPlan {
        var plan = (try? Knowledge.playbook(genre).defaultPlan) ?? ShotPlan(
            genre: genre, genreConfidence: 1, subject: .none,
            composition: Composition(ratio: .standard, anchor: .init(x: 0.5, y: 0.5), subjectSize: .init(min: 0.3, max: 0.6), levelHorizon: false),
            exposure: ExposureIntent(meter: .scene, subjectEV: 0, highlightClipMax: 0.01),
            moment: [], rationale: rationale)
        if let ratio { plan.composition.ratio = ratio }
        if genre == .portrait { plan.composition.anchor = .init(x: 0.62, y: 0.36) }
        plan.rationale = rationale
        return plan
    }

    private func demoCrop(_ plan: ShotPlan, _ subject: CameraCore.NormalizedRect?) -> CameraCore.NormalizedRect {
        CompositionSolver.solve(subject: subject, composition: plan.composition, sensorAspect: Executor.sensorAspect,
                                salientCenter: CameraCore.NormalizedPoint(x: 0.5, y: 0.35)).crop
    }

    private func demoMoment(_ plan: ShotPlan, eyes: Double?) -> MomentReport {
        var scorer = MomentScorer(plan: plan, startedAt: 0)
        let face = Subject(id: 1, kind: .face, box: .init(x: 0.52, y: 0.28, width: 0.2, height: 0.16), confidence: 0.95,
                           yaw: 8, pitch: 0, roll: 0, eyeOpenness: eyes, faceQuality: 0.7)
        let m = SceneMeasurement(
            timestamp: 0, subjects: eyes == nil ? [] : [face], primarySubjectID: eyes == nil ? nil : 1,
            luminance: LuminanceStats(histogram: Array(repeating: 1.0 / 64, count: 64), clipHigh: 0.002, clipLow: 0,
                                      mean: 0.45, subjectMean: 0.5),
            sharpness: Sharpness(global: 0.7, subject: 0.75), horizonDegrees: 0.4, deviceAngularSpeed: 0.04,
            subjectSpeed: 0, sceneChange: 0, aesthetics: nil)
        return scorer.update(m, now: 0, placementError: 0.02, exposureSettled: true).withoutFire
    }

    private func demoRubric(_ base: Int, light: Int, moment: Int) -> RubricResult {
        let evidence: [RubricCriterion: String] = [
            .clarity: "主体清晰度 0.75，手机角速度 0.04", .exposure: "clipHigh=0.002，脸部亮度 0.50",
            .composition: "脸在右三分附近，就位误差 0.02", .light: "左后方逆光勾出发丝轮廓",
            .background: "背景是虚化的树影，无杂物", .moment: "表情放松，视线朝画面左侧",
            .genre: "眼神自然，有情绪"
        ]
        let scores = RubricCriterion.allCases.map { criterion -> RubricScore in
            let value = criterion == .light ? light : (criterion == .moment ? moment : base)
            return RubricScore(criterion: criterion, score: value, evidence: evidence[criterion] ?? "")
        }
        return RubricResult(scores: scores)
    }
}
#endif
