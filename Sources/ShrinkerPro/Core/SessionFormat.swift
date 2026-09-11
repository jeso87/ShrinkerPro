import Foundation

/// The format every raster file is converted to for the rest of this
/// session, when the user has set the main window's override. `nil`
/// (no override) is represented by the absence of a value, not a case here.
///
/// Deliberately its own type rather than a fourth case on `ConversionFormat`,
/// for two reasons that both come down to `ConversionFormat` being
/// *persisted*:
///
///   - `SettingsView`'s rows iterate `allCases` on purpose, so that they
///     always offer exactly the cases the type has and nothing can fall out
///     of sync. Adding `.png` to `ConversionFormat` would therefore put a
///     "PNG" option in the HEIC/HEIF row as a side effect of a change that
///     had nothing to do with it.
///   - It would make `"png"` a value `Settings.readFormat` accepts and
///     stores for a rule the UI has no way to express.
///
/// This type is never written to UserDefaults. It exists for the length of
/// one run of the app and is gone at quit — which, together with the bar
/// being visible in the main window the whole time it is set, is what
/// distinguishes it from the persistent global override that
/// `2026-09-10-format-conversion.md` rejected.
enum SessionFormat: String, CaseIterable, Equatable, Sendable {
    case jpeg
    case webp
    case avif
    /// Reachable only here — PNG is not one of the persisted per-format
    /// rules. See `ConversionRouter.convert(native:to:)`.
    case png

    var displayName: String {
        switch self {
        case .jpeg: return "JPEG"
        case .webp: return "WebP"
        case .avif: return "AVIF"
        case .png: return "PNG"
        }
    }

    /// The routing vocabulary's equivalent of this choice.
    var targetFormat: TargetFormat {
        switch self {
        case .jpeg: return .jpeg
        case .webp: return .webp
        case .avif: return .avif
        case .png: return .png
        }
    }
}
