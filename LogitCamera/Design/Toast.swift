import SwiftUI

struct ToastAction {
    let title: String
    let run: () -> Void
}

/// 单行细线提示。错误类使用 warning 色；接管提示可带「恢复 AI」。
struct Toast: View {
    let text: String
    let isWarning: Bool
    var action: ToastAction?

    var body: some View {
        HStack(spacing: 10) {
            Text(text)
                .font(Theme.Typeface.body)
                .foregroundStyle(isWarning ? Theme.Palette.warning : Theme.Palette.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if let action {
                Rectangle().fill(Theme.Palette.hairline).frame(width: 1, height: 14)
                Button(action.title, action: action.run)
                    .font(Theme.Typeface.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("toast.action")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 36)
        .background(Color.black.opacity(0.72), in: Capsule())
        .overlay(Capsule().stroke(isWarning ? Theme.Palette.warning.opacity(0.5) : Theme.Palette.hairline,
                                  lineWidth: 1))
        .hudTypeSize()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("camera.notice")
    }
}

#Preview {
    VStack(spacing: 12) {
        Toast(text: "你接管了光圈 · AI 已停止", isWarning: false, action: ToastAction(title: "恢复 AI") {})
        Toast(text: "AI 密钥无效或额度不足", isWarning: true)
    }
    .padding()
    .background(.black)
}
