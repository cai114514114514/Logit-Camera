import CameraCore
import SwiftUI

/// 出新方案时在取景框底部浮出一行：题材与理由。4 秒后淡出。
struct AIAnnotation: View {
    let agent: AgentController
    @State private var visibleID: UUID?

    private var planID: UUID? { agent.isDefaultPlan ? nil : agent.plan?.id }

    var body: some View {
        ZStack {
            if let id = visibleID, id == planID, agent.isEnabled, let plan = agent.plan {
                content(plan).transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .animation(.easeOut(duration: 0.3), value: visibleID)
        .allowsHitTesting(false)
        .task(id: planID) {
            guard let id = planID else { return }
            visibleID = id
            guard (try? await Task.sleep(for: Theme.Motion.annotationLifetime)) != nil else { return }
            if visibleID == id { visibleID = nil }
        }
    }

    private func content(_ plan: ShotPlan) -> some View {
        VStack(spacing: 3) {
            Text(agent.genreName ?? plan.genre.rawValue)
                .font(Theme.Typeface.labelMono)
                .foregroundStyle(Theme.Palette.accent)
            Text(plan.rationale)
                .font(Theme.Typeface.body)
                .foregroundStyle(Theme.Palette.ink)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.Palette.accentDim, lineWidth: 1))
        .hudTypeSize()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("camera.annotation")
    }
}
