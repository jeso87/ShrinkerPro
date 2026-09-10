import SwiftUI
import AppKit

/// Design tokens for the visual redesign, converted from the spec's OKLCh
/// values to sRGB hex. This is deliberately the *only* colour palette in the
/// app: everything else in the UI uses standard SwiftUI semantic colours
/// (`.primary`, `.secondary`, `Color(nsColor: .windowBackgroundColor)`, …),
/// which already track appearance and accessibility settings correctly.
///
/// These tokens exist specifically for the places the coral→ice brand
/// gradient survives — the app icon, the drop-zone glow, and the savings
/// bars/percent — so they are dynamic (dark/light resolved from the current
/// `NSAppearance` at render time) rather than a hard-coded scheme.
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

    static let gradientStart = dynamic(darkHex: "#ED7665", lightHex: "#D55948")
    static let gradientEnd = dynamic(darkHex: "#7FAFE2", lightHex: "#6197CD")

    /// `LinearGradient(colors:, startPoint: .leading, endPoint: .trailing)`,
    /// per the spec, for the 150×3pt savings bar fill.
    static var barGradient: LinearGradient {
        LinearGradient(colors: [gradientStart, gradientEnd], startPoint: .leading, endPoint: .trailing)
    }

    // MARK: App icon gradient

    static let iconGradientStart = dynamic(darkHex: "#E6705F", lightHex: "#E36654")
    static let iconGradientEnd = dynamic(darkHex: "#79A9DB", lightHex: "#679DD4")

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
    static let savingsAccent = dynamic(darkHex: "#FFB09D", lightHex: "#BD4334")

    /// Tint for the drop-zone's radial-gradient glow.
    static let dropGlow = dynamic(darkHex: "#E17363", darkAlpha: 0.13, lightHex: "#E17363", lightAlpha: 0.12)
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
