import SwiftUI

/// AI 开关。字形是一个细线圆（镜头）和偏心的瞳孔：
/// AI 就绪或倒计时时瞳孔移到中心，表示「对准了」。
struct AIButton: View {
    let isOn: Bool
    /// AI 已放行（就绪或正在拍）：瞳孔移到中心，表示「对准了」。
    let aligned: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                LogitGlyph()
                    .stroke(isOn ? Theme.Palette.accent : Theme.Palette.inkSecondary, lineWidth: 1.4)
                    .overlay {
                        LogitGlyph.Pupil(offset: aligned ? .zero : CGSize(width: 0.28, height: -0.22))
                            .fill(isOn ? Theme.Palette.accent : Theme.Palette.inkSecondary)
                    }
                    .frame(width: 22, height: 22)
                    .animation(.spring(duration: 0.4), value: aligned)
                Text("AI")
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                    .foregroundStyle(isOn ? Theme.Palette.accent : Theme.Palette.inkSecondary)
            }
            .frame(width: 56, height: 56)
            .background {
                Circle()
                    .stroke(isOn ? Theme.Palette.accent : Theme.Palette.hairline, lineWidth: 1)
                    .shadow(color: isOn ? Theme.Palette.accent.opacity(0.55) : .clear, radius: 8)
            }
            .contentShape(Circle())
        }
        .accessibilityLabel("AI 自动相机")
        .accessibilityValue(isOn ? "已开启" : "已关闭")
        .accessibilityHint("自动选择光圈、曝光、变焦和照片画幅")
        .accessibilityIdentifier("camera.ai")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Logit 字形外圈：细线圆。
struct LogitGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        Path(ellipseIn: rect.insetBy(dx: 0.7, dy: 0.7))
    }

    /// 瞳孔：半径为外圈 28% 的实心圆，按外圈半径比例偏移。
    struct Pupil: Shape {
        var offset: CGSize
        var animatableData: AnimatablePair<CGFloat, CGFloat> {
            get { AnimatablePair(offset.width, offset.height) }
            set { offset = CGSize(width: newValue.first, height: newValue.second) }
        }

        func path(in rect: CGRect) -> Path {
            let radius = min(rect.width, rect.height) / 2
            let r = radius * 0.28
            let center = CGPoint(x: rect.midX + offset.width * radius, y: rect.midY + offset.height * radius)
            return Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        }
    }
}

#Preview {
    HStack(spacing: 30) {
        AIButton(isOn: false, aligned: false) {}
        AIButton(isOn: true, aligned: false) {}
        AIButton(isOn: true, aligned: true) {}
    }
    .padding()
    .background(.black)
}
