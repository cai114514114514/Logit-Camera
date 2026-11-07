import SwiftUI

/// 选片完成后的一组缩略图（规格 §2.3）。
struct BurstPreview: Identifiable {
    let id = UUID()
    let thumbnails: [UIImage]
    let chosen: Int
}

/// 连拍的 6 张依次弹出，被选中的那张抬起、描青边、标「AI 选择」。
struct BurstFilmstrip: View {
    let preview: BurstPreview
    @State private var shown = false
    @State private var picked = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(preview.thumbnails.enumerated()), id: \.offset) { index, image in
                let chosen = index == preview.chosen
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 34, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .stroke(Theme.Palette.accent.opacity(chosen && picked ? 1 : 0), lineWidth: 2))
                    .overlay(alignment: .top) {
                        if chosen && picked {
                            Text("AI 选择")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Theme.Palette.accent, in: Capsule())
                                .fixedSize()
                                .offset(y: -16)
                                .transition(.opacity)
                        }
                    }
                    .shadow(color: .black.opacity(0.6), radius: 6, y: 3)
                    .scaleEffect(chosen && picked ? 1.12 : (shown ? 1 : 0.8))
                    .offset(y: chosen && picked ? -8 : (shown ? 0 : 20))
                    .opacity(shown ? (picked && !chosen ? 0.45 : 1) : 0)
                    .animation(reduceMotion ? .easeOut(duration: 0.2)
                               : .spring(duration: 0.4, bounce: 0.25).delay(Double(index) * 0.07), value: shown)
                    .animation(.spring(duration: 0.35, bounce: 0.3), value: picked)
            }
        }
        .task(id: preview.id) {
            shown = false
            picked = false
            try? await Task.sleep(for: .milliseconds(30))
            shown = true
            try? await Task.sleep(for: .milliseconds(700))
            picked = true
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("从 \(preview.thumbnails.count) 张里选了第 \(preview.chosen + 1) 张")
        .accessibilityIdentifier("camera.burstPreview")
    }
}
