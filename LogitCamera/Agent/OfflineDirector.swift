#if DEBUG
import CameraCore
import Foundation

/// 调试用的离线「模型」（启动参数 `-LogitOfflineDirector`）：侦察总是返回 general，
/// 导演请求总是失败。用于在真机上不花 API 额度地跑完整的本机闭环（镜头、曝光、时机、连拍）。
struct OfflineDirector: VisionModel {
    func scout(_ frame: ModelFrame, plan: ShotPlan?) async throws -> ScoutResult {
        try await Task.sleep(for: .milliseconds(300))
        return ScoutResult(genre: .general, confidence: 0.5, sceneChanged: false, planStillValid: plan != nil,
                           subjectHint: .salient, reason: "离线调试")
    }

    func direct(_ frame: ModelFrame, playbook: GenrePlaybook, plan: ShotPlan?,
                memory: DirectorMemory?, feedback: String) async throws -> DirectorOutcome {
        try await Task.sleep(for: .milliseconds(300))
        throw ModelError.transport("离线调试")
    }
}
#endif
