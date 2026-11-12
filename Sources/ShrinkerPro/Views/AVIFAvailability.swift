import SwiftUI

/// How the format menus show AVIF on a system that can't write it (macOS 14
/// and 15). It stays listed, greyed out, with the reason in its own label:
/// hiding it would read as the feature having been removed. Shared by
/// Settings, the session bar and Studio's format menu, so all three say the
/// same thing. The engine refuses an AVIF output there too
/// (`ShrinkError.avifUnavailable`), so a stored choice can't slip through.
enum AVIFAvailability {
    static var canWrite: Bool { RasterUTType.canWriteAVIF }

    /// A menu item's text: the format name, with the requirement added when
    /// this system can't write it.
    static func menuLabel(_ name: String, isAVIF: Bool) -> String {
        guard isAVIF, !canWrite else { return name }
        return String(localized: "\(name) (needs macOS \(RasterUTType.avifWritingMacOS))",
                      comment: "A greyed-out format menu item on macOS 14 or 15, which can't write AVIF. Placeholders: the format name (AVIF, stays English) and a macOS version number such as 26.")
    }

    /// The sentence a settings footer or tooltip adds when this system can't
    /// write AVIF, or nil when it can.
    static var note: String? {
        guard !canWrite else { return nil }
        return String(localized: "This Mac reads AVIF but can't write it: that needs macOS \(RasterUTType.avifWritingMacOS) or later.",
                      comment: "Note under the conversion rules on macOS 14 or 15. The placeholder is a macOS version number such as 26.")
    }
}

extension View {
    /// Greys out a format menu item this system can't write.
    func avifItemDisabled(_ isAVIF: Bool) -> some View {
        disabled(isAVIF && !AVIFAvailability.canWrite)
    }
}
