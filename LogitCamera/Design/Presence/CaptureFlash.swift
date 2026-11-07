import SwiftUI

/// 拍下的一瞬间：取景画面闪白（0.45 秒，峰值 0.85）。减少动态效果时只轻闪一下。
struct CaptureFlash: View {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Rectangle()
            .fill(Color.white)
            .keyframeAnimator(initialValue: 0.0, trigger: trigger) { content, value in
                content.opacity(value)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(reduceMotion ? 0.3 : 0.85, duration: 0.06)
                    CubicKeyframe(0, duration: reduceMotion ? 0.2 : 0.39)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
