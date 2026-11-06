import CameraCore
import SwiftUI

/// AI 的裁切框：框外压暗，青色细线与四角刻线；主体外有一个很淡的括号。
struct CropOverlay: View {
    let crop: CameraCore.NormalizedRect
    let subject: CameraCore.NormalizedRect?

    var body: some View {
        GeometryReader { geometry in
            let frame = rect(crop, in: geometry.size)
            ZStack {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geometry.size))
                    path.addRect(frame)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                Rectangle()
                    .stroke(Theme.Palette.accent.opacity(0.7), lineWidth: 1)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                if let subject {
                    let box = rect(subject, in: geometry.size).insetBy(dx: -6, dy: -6)
                    CornerTicks(length: 10)
                        .stroke(Theme.Palette.accent.opacity(0.45), lineWidth: 1)
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)
                }
            }
            .animation(.linear(duration: 0.1), value: crop)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AI 裁切框")
        .accessibilityAddTraits(.isImage)
        .accessibilityIdentifier("camera.crop")
    }

    private func rect(_ r: CameraCore.NormalizedRect, in size: CGSize) -> CGRect {
        CGRect(x: r.x * size.width, y: r.y * size.height, width: r.width * size.width, height: r.height * size.height)
    }
}
