import CameraCore
import SwiftUI

/// AI 的构图：框外压暗（框的边缘由极光负责）；认出主体时，白色细角框以弹簧动画「析出」落到主体上。
struct CropOverlay: View {
    let crop: CameraCore.NormalizedRect
    let subject: CameraCore.NormalizedRect?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let frame = rect(crop, in: geometry.size)
            ZStack {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geometry.size))
                    path.addRect(frame)
                }
                .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                .animation(.linear(duration: 0.1), value: crop)
                if let subject {
                    let box = rect(subject, in: geometry.size).insetBy(dx: -8, dy: -8)
                    CornerTicks(length: 12)
                        .stroke(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)
                        .animation(.linear(duration: 0.12), value: subject)
                        .transition(reduceMotion ? .opacity : .scale(scale: 1.15).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.45, bounce: 0.3), value: subject == nil)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AI 构图框")
        .accessibilityAddTraits(.isImage)
        .accessibilityIdentifier("camera.crop")
    }

    private func rect(_ r: CameraCore.NormalizedRect, in size: CGSize) -> CGRect {
        CGRect(x: r.x * size.width, y: r.y * size.height, width: r.width * size.width, height: r.height * size.height)
    }
}
