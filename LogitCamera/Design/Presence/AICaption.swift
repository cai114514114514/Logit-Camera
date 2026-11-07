import SwiftUI

/// AI 的一句人话，像字幕一样浮在取景器底部（规格 §2.4）。文字变化时淡入淡出，并给 VoiceOver 播报。
struct AICaption: View {
    let text: String?

    var body: some View {
        ZStack {
            if let text {
                Text(text)
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.9), radius: 6)
                    .shadow(color: .black.opacity(0.5), radius: 1)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .id(text)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .animation(.easeOut(duration: 0.35), value: text)
        .hudTypeSize()
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("camera.caption")
        .onChange(of: text) { _, value in
            guard let value else { return }
            AccessibilityNotification.Announcement(value).post()
        }
    }
}
