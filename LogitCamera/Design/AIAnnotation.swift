import CameraCore
import SwiftUI

/// AI 每次调整成功后，在取景框底部浮出一行：哪些参数变了，以及为什么。4 秒后淡出。
struct AIAnnotation: View {
    let agent: CameraAgent
    @State private var visibleID: UUID?

    var body: some View {
        ZStack {
            if let id = visibleID, id == agent.adjustmentID {
                content.transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .animation(.easeOut(duration: 0.3), value: visibleID)
        .allowsHitTesting(false)
        .task(id: agent.adjustmentID) {
            guard let id = agent.adjustmentID else { return }
            visibleID = id
            guard (try? await Task.sleep(for: Theme.Motion.annotationLifetime)) != nil else { return }
            if visibleID == id { visibleID = nil }
        }
    }

    private var content: some View {
        VStack(spacing: 4) {
            if !agent.changes.isEmpty {
                HStack(spacing: 10) {
                    ForEach(agent.changes) { change in
                        HStack(spacing: 3) {
                            Text(change.before).foregroundStyle(Theme.Palette.inkTertiary)
                            Image(systemName: "arrow.right").font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Theme.Palette.accentDim)
                            Text(change.after).foregroundStyle(Theme.Palette.accent)
                        }
                    }
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
            if !agent.reason.isEmpty {
                Text(agent.reason)
                    .font(Theme.Typeface.body)
                    .foregroundStyle(Theme.Palette.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
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
