import CameraCore
import SwiftUI

/// Logit Camera 的视觉语言：「精密仪器」。
/// accent 只属于 AI；用户设定为白色，系统自动为灰色。
enum Theme {
    enum Palette {
        static let background = Color.black
        static let ink = Color.white.opacity(0.92)
        static let inkSecondary = Color.white.opacity(0.6)
        static let inkTertiary = Color.white.opacity(0.38)
        static let hairline = Color.white.opacity(0.18)
        static let accent = Color(red: 0x3D / 255, green: 0xF5 / 255, blue: 0xC8 / 255)
        static let accentDim = accent.opacity(0.35)
        static let warning = Color(red: 0xFF / 255, green: 0xB5 / 255, blue: 0x47 / 255)
        static let scrim = Color.black.opacity(0.4)
    }

    enum Typeface {
        static var readout: Font { .system(size: 13, weight: .medium, design: .monospaced).monospacedDigit() }
        static var readoutLarge: Font { .system(size: 15, weight: .medium, design: .monospaced).monospacedDigit() }
        static var label: Font { .system(size: 10, weight: .semibold) }
        static var body: Font { .system(size: 12, weight: .regular) }
        static var countdown: Font { .system(size: 30, weight: .ultraLight, design: .rounded).monospacedDigit() }
    }

    enum Metric {
        static let hairline: CGFloat = 1
        static let cornerTick: CGFloat = 18
        static let hudHeight: CGFloat = 44
        static let statusHeight: CGFloat = 28
        static let gutter: CGFloat = 16
    }

    enum Motion {
        static let breathPeriod: Double = 3
        static let scanDuration: Double = 0.9
        static let annotationLifetime: Duration = .seconds(4)
    }

    static func color(for origin: ValueOrigin) -> Color {
        switch origin {
        case .automatic: Palette.inkSecondary
        case .user: Palette.ink
        case .ai: Palette.accent
        }
    }
}

extension View {
    /// HUD 文本最多放大到 accessibility1，避免撑破单行布局。
    func hudTypeSize() -> some View { dynamicTypeSize(...DynamicTypeSize.accessibility1) }
}
