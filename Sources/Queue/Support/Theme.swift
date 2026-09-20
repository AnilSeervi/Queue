import SwiftUI

// Design tokens transcribed from design_handoff_queue_menubar/README.md.
// All views resolve colors through `DS` so dark/light stay in sync with the
// system appearance (spec 1a dark / 1b light).

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1
        )
    }
}

struct DS {
    let dark: Bool

    init(_ scheme: ColorScheme) { self.dark = scheme == .dark }

    /// white-opacity in dark, black-opacity in light
    private func mono(_ white: Double, _ black: Double) -> Color {
        dark ? Color.white.opacity(white) : Color.black.opacity(black)
    }

    // MARK: Surfaces
    var panelTint: Color { dark ? Color(.sRGB, red: 30/255, green: 31/255, blue: 36/255, opacity: 0.88)
                                : Color(.sRGB, red: 246/255, green: 246/255, blue: 249/255, opacity: 0.86) }
    var panelBorder: Color { mono(0.13, 0.10) }
    var hairline: Color { mono(0.08, 0.07) }
    var rowHover: Color { mono(0.05, 0.035) }
    var card: Color { mono(0.055, 0.05) }
    var control: Color { mono(0.10, 0.06) }
    var controlActive: Color { mono(0.14, 0.09) }
    /// Opaque-ish color behind the hover action cluster gradient (dark #26272e).
    var hoverFadeBase: Color { dark ? Color(hex: 0x26272E) : Color(hex: 0xE8E8EC) }

    // MARK: Text
    var textPrimary: Color { dark ? Color(hex: 0xF5F5F7) : Color(hex: 0x1D1D1F) }
    var textSecondary: Color { mono(0.55, 0.55) }
    var textMeta: Color { mono(0.42, 0.42) }
    var textFaint: Color { mono(0.35, 0.35) }
    var textGroupHeader: Color { mono(0.50, 0.50) }
    var textGroupCount: Color { mono(0.30, 0.30) }

    // MARK: Semantic
    var success: Color { dark ? Color(hex: 0x5FD58A) : Color(hex: 0x1A8A44) }
    /// Approve green — Approve button and "n approved this session" line
    /// (spec: dark #7ee2a0, lighter than `success`; light reuses success).
    var approve: Color { dark ? Color(hex: 0x7EE2A0) : Color(hex: 0x1A8A44) }
    var danger: Color { dark ? Color(hex: 0xFF7369) : Color(hex: 0xD43C2E) }
    var attention: Color { dark ? Color(hex: 0xF0B429) : Color(hex: 0xD99A06) }
    /// Light-mode tab count chip text (#b07800); dark uses `attention`.
    var attentionBadgeText: Color { dark ? Color(hex: 0xF0B429) : Color(hex: 0xB07800) }
    var merge: Color { dark ? Color(hex: 0xCBA6F7) : Color(hex: 0x6B3FB5) }
    var info: Color { Color(hex: 0x7BB8F0) }
    var perfWarn: Color { Color(hex: 0xFF9F6B) }
    var link: Color { Color(hex: 0x2A6FD6) }
    var toggleOn: Color { Color(hex: 0x34C759) }

    // Issue label chip colors (dark palette per spec; reused in light).
    func issueLabelColor(_ name: String) -> Color {
        switch name {
        case "ci": return Color(hex: 0xF0B429)
        case "perf": return Color(hex: 0xFF9F6B)
        case "a11y": return Color(hex: 0x7BB8F0)
        case "bug": return Color(hex: 0xFF7369)
        default: return textSecondary
        }
    }
}

// MARK: - Type scale (README "Design Tokens")
enum DSFont {
    static func capsLabel() -> Font { .system(size: 9.5, weight: .semibold) }       // 9.5 caps-label
    static func pill() -> Font { .system(size: 10.5, weight: .medium) }             // 10.5 pill/age
    static func chipCount() -> Font { .system(size: 10.5, weight: .semibold) }      // tab count chip
    static func meta() -> Font { .system(size: 11) }                                // 11 meta
    static func metaMono() -> Font { .system(size: 11, weight: .semibold, design: .monospaced) } // repo header
    static func legend() -> Font { .system(size: 11.5) }                            // 11.5 legend
    static func tab() -> Font { .system(size: 12.5, weight: .medium) }              // 12.5 tab
    static func button() -> Font { .system(size: 11, weight: .semibold) }           // hover action buttons
    static func rowTitle() -> Font { .system(size: 13, weight: .medium) }           // 13 row title
    static func sectionLabel() -> Font { .system(size: 11, weight: .semibold) }     // stats section label
    static func statNumber() -> Font { .system(size: 20, weight: .semibold) }       // 20 stat number
    static func statCaption() -> Font { .system(size: 10.5) }
    static func onboardingTitle() -> Font { .system(size: 16, weight: .semibold) }
    static func onboardingTitleSmall() -> Font { .system(size: 15, weight: .semibold) }
    static func onboardingBody() -> Font { .system(size: 11.5) }
    static func deviceCode() -> Font { .system(size: 24, weight: .semibold, design: .monospaced) }
    static func avatarInitials() -> Font { .system(size: 8, weight: .bold) }
}

// MARK: - Metrics
enum DSMetric {
    static let panelWidth: CGFloat = 440
    static let panelRadius: CGFloat = 14
    static let contentHeight: CGFloat = 400
    static let gutter: CGFloat = 14
}
