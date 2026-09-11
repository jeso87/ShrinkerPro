import Foundation

/// How much of an image's metadata survives compression.
///
/// Orientation is deliberately *not* governed by this. It is applied to the
/// pixels and absent from the output under all three policies — see
/// `ImageMetadata`. An orientation tag is not a fact about the image, it is
/// an instruction about how to draw it, and by the time anything here runs
/// that instruction has already been carried out. Leaving the tag behind
/// afterwards would rotate the image a second time.
///
/// `rawValue` is the UserDefaults persistence format — see `Settings` — so
/// renaming a case here is a migration, not a free rename.
enum MetadataPolicy: String, CaseIterable, Equatable, Sendable {

    /// Everything the source carried, minus orientation.
    ///
    /// The default, and the only value that doesn't silently delete data on
    /// upgrade: JPEG → JPEG preserves EXIF *today*, because mozjpeg's cjpeg
    /// sets `copy_markers = TRUE` for a JPEG input
    /// (vendor/src/mozjpeg/cjpeg.c:124-125) and rdjpeg.c:65-68 saves every
    /// APPn marker. Any other default would start stripping capture data
    /// from files this app currently round-trips intact, without asking.
    case all

    /// Rights and attribution only — see `ImageMetadata.copyrightTagRoots`.
    /// Everything else, including GPS and capture time, is dropped.
    case copyright

    /// Nothing at all.
    ///
    /// Spelled `stripped` rather than `none` on purpose: a case literally
    /// named `none` on an enum that is also used as `MetadataPolicy?`
    /// collides with `Optional.none` at every call site that relies on type
    /// inference. The *stored* value is still `"none"`, which is what the
    /// setting means to a reader of the defaults database.
    case stripped = "none"

    var displayName: String {
        switch self {
        case .all: return "All metadata"
        case .copyright: return "Copyright and credit only"
        case .stripped: return "No metadata"
        }
    }
}
