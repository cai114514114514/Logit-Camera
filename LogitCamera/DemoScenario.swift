#if DEBUG
import CameraCore
import Foundation

/// 仅调试版：`-LogitDemo <scenario>` 直接展示某个 AI 状态，用于不消耗 API 额度的界面截图。
/// 演示期间 `CameraAgent.demoLocked` 阻止真实循环启动，不发任何网络请求。
enum DemoScenario: String, CaseIterable {
    case idle, observing, adjusted, ready, countdown, manual, error

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
        guard scenario != .idle else { return }
        agent.isEnabled = true
        agent.round = 3
        agent.reason = "主体处在逆光中偏暗，提高曝光并收小光圈，让人物和背景都清楚。"

        switch scenario {
        case .idle:
            break
        case .observing:
            agent.stage = .observing
            agent.status = "观察画面"
            Task { [weak agent] in
                while let agent, agent.isEnabled {
                    agent.stage = .observing
                    agent.observationTick += 1
                    try? await Task.sleep(for: .seconds(1.2))
                    agent.stage = .thinking
                    try? await Task.sleep(for: .seconds(3.8))
                }
            }
        case .adjusted:
            agent.stage = .verifying
            agent.status = "已调整 · 等待复核"
            agent.changes = ParameterDelta.changed([
                ParameterDelta(id: "aperture", title: "光圈", before: "ƒ/1.48", after: "ƒ/4"),
                ParameterDelta(id: "bias", title: "曝光", before: "±0.0", after: "+0.3"),
                ParameterDelta(id: "ratio", title: "画幅", before: "3:4", after: "3:4")
            ])
            Task { @MainActor in
                // 在真实硬件上设定光圈，以展示 HUD 中「AI 设定」的青色读数。
                await waitUntilReady()
                capture.setAperture(4)
                agentOwnsSettings = true
                // 标注 4 秒后淡出；演示中每 3 秒重新触发，保证截图时可见。
                while agent.isEnabled {
                    agent.adjustmentID = UUID()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        case .ready:
            agent.stage = .ready
            agent.status = "准备拍摄 · 1/2 次确认"
            agent.confirmationCount = 1
        case .countdown:
            agent.confirmationCount = 2
            agent.status = "保持稳定 · 即将拍照"
            Task { [weak agent] in
                while let agent, agent.isEnabled {
                    for number in [3, 2, 1] {
                        agent.stage = .countdown
                        agent.countdown = number
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
            }
        case .manual:
            agent.isEnabled = false
            agent.reason = ""
            post("你接管了光圈 · AI 已停止", offersResume: true, sticky: true)
        case .error:
            agent.isEnabled = false
            agent.faulted = true
            agent.status = "AI 需要检查密钥"
            agent.reason = "密钥无效或账户额度不足，请检查 AI 设置。"
            agent.stage = .paused
        }
    }

    private func waitUntilReady() async {
        for _ in 0..<100 where state.phase != .ready {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
#endif
