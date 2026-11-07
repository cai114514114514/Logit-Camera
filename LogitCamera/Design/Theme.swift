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
        // 全部基于文字样式，跟随动态字体；HUD 用 hudTypeSize() 限制上限。
        static var readout: Font { .system(.footnote, design: .monospaced, weight: .medium).monospacedDigit() }
        static var readoutLarge: Font { .system(.subheadline, design: .monospaced, weight: .medium).monospacedDigit() }
        static var label: Font { .system(.caption2, weight: .semibold) }
        static var labelMono: Font { .system(.caption2, design: .monospaced, weight: .medium) }
        static var body: Font { .system(.caption) }
        static var bodyMono: Font { .system(.caption, design: .monospaced, weight: .medium) }
    }

    enum Metric {
        static let hairline: CGFloat = 1
        static let cornerTick: CGFloat = 18
        static let hudHeight: CGFloat = 44
        static let gutter: CGFloat = 16
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
