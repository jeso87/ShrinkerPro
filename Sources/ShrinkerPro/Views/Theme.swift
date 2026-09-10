import SwiftUI
import AppKit

/// Design tokens for the visual redesign, converted from the spec's OKLCh
/// values to sRGB hex. This is deliberately the *only* colour palette in the
/// app: everything else in the UI uses standard SwiftUI semantic colours
/// (`.primary`, `.secondary`, `Color(nsColor: .windowBackgroundColor)`, …),
/// which already track appearance and accessibility settings correctly.
///
/// These tokens exist specifically for the places the brand gradient shows —
/// the drop-zone glow and icon, and the savings bars/percent — so they are
/// dynamic (dark/light resolved from the current `NSAppearance` at render
/// time) rather than a hard-coded scheme.
///
/// The palette is derived from `Logo.icon`, not chosen freehand. Sampling the
/// rendered icon by frequency and saturation gives a run from cyan (hue ~187)
/// through blue (hue ~210-222, and the single most common colour at #002880)
/// to violet (hue ~258), with pale cyan highlights around #B0F0F8. Every value
/// below sits inside that range, so the window and its icon read as one thing.
///
/// It replaces the coral→ice palette inherited from the visual redesign
/// (see docs/design/specs/2026-09-09-visual-redesign.md), which predated this
/// logo and clashed with it — warm orange bars beneath a blue-violet icon.
enum Theme {

    /// Wraps a dark/light hex pair in an `NSColor` whose `dynamicProvider`
    /// re-resolves on every appearance change, so a single `Color` value
    /// stays correct across Dark Mode switches without callers having to
    /// re-check `colorScheme` themselves.
    private static func dynamic(darkHex: String, darkAlpha: Double = 1, lightHex: String, lightAlpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(shrinkerHex: darkHex, alpha: darkAlpha)
                : NSColor(shrinkerHex: lightHex, alpha: lightAlpha)
        })
    }

    // MARK: Savings bar gradient (result rows)

    /// Violet → cyan, left to right: the same sweep the icon makes, so a row
    /// of savings bars echoes the app's own mark. The light-mode pair is
    /// darkened rather than merely re-tinted — the dark values are legible on
    /// a dark row but wash out against a white one at 3pt tall.
    static let gradientStart = dynamic(darkHex: "#6B5CE7", lightHex: "#5646C8")
    static let gradientEnd = dynamic(darkHex: "#6FDCF5", lightHex: "#2FA9CC")

    /// `LinearGradient(colors:, startPoint: .leading, endPoint: .trailing)`,
    /// per the spec, for the 150×3pt savings bar fill.
    static var barGradient: LinearGradient {
        LinearGradient(colors: [gradientStart, gradientEnd], startPoint: .leading, endPoint: .trailing)
    }

    // MARK: App icon gradient

    /// Deep blue → violet, mirroring the logo's own diagonal: the sampled
    /// background runs #002880 in its dark corner to #5322D7 in its bright
    /// one. Lifted slightly from those raw values so the small circle in the
    /// drop zone doesn't read as a black dot at 44pt.
    static let iconGradientStart = dynamic(darkHex: "#2A4FD0", lightHex: "#1E3FB0")
    static let iconGradientEnd = dynamic(darkHex: "#6A35E8", lightHex: "#5322D7")

    /// 145° diagonal, per the spec, for the icon's gradient circle.
    static var iconGradient: LinearGradient {
        LinearGradient(
            colors: [iconGradientStart, iconGradientEnd],
            startPoint: UnitPoint(x: 0.25, y: 0.0),
            endPoint: UnitPoint(x: 0.75, y: 1.0)
        )
    }

    // MARK: Accents

    /// The percent figure on a result row, and the size portion of the
    /// session aggregate in the "Recent" header.
    /// Cyan on dark, deep blue on light — the two ends of the logo's range
    /// that survive being set as bold 13.5pt text. The pale #B0F0F8 sampled
    /// from the icon's highlights is too low-contrast for type on a light
    /// background, so light mode takes the blue end instead of a tint of the
    /// same cyan.
    static let savingsAccent = dynamic(darkHex: "#7FE0F5", lightHex: "#1E56C8")

    /// Tint for the drop-zone's radial-gradient glow.
    static let dropGlow = dynamic(darkHex: "#4B4FE0", darkAlpha: 0.16, lightHex: "#4B4FE0", lightAlpha: 0.10)
}

private extension NSColor {
    /// `hex` is a 6-digit RGB string, with or without a leading `#`.
    convenience init(shrinkerHex hex: String, alpha: Double) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: digits).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
}
