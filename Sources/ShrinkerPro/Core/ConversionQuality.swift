import Foundation

// Where `.standard`'s numbers come from, kept from the fixed-quality
// version this file replaced:
//
// 80 was chosen because it is the value the format-conversion spec's own
// measured baseline used for WebP ("WebP (cwebp -q 80) 18,828 bytes"
// against the project's 244,413-byte PNG fixture) — using the same number
// meant output sizes stayed directly comparable to that baseline rather
// than being coincidentally-close-but-different. It sits in the normal
// "visually lossless for photographic content" range quoted for both
// AV1-family (AVIF) and WebP encoders.
//
// That version deliberately did not touch cjpeg: the same-format JPEG path
// shipped at cjpeg's own default of 75, unspecified on its command line.
// `.standard` preserves that exactly — see `QualitySettings.cjpegQuality`,
// where the distinction between "75" and "unspecified" turns out to matter.

/// The three encoder-specific numbers one `QualityLevel` resolves to. They
/// are separate fields rather than one shared 0...100 because the encoders do
/// not agree on a scale — ImageIO wants a unit double, cwebp an integer
/// percentage, cjpeg an integer percentage it interprets differently again.
struct QualitySettings: Equatable, Sendable {
    /// 0...1, as ImageIO's `kCGImageDestinationLossyCompressionQuality` expects.
    var unitScale: Double
    /// 0...100, as cwebp's `-q` flag expects.
    var cwebpScale: Int
    /// 0...100, as cjpeg's `-quality` flag expects — or `nil` to omit the
    /// flag altogether and let cjpeg use its own built-in default.
    ///
    /// The `nil` case exists because omitting `-quality` is genuinely not the
    /// same as passing cjpeg's own default of 75: mozjpeg's
    /// `set_quality_ratings` also sets default subsampling as a side effect
    /// (vendor/src/mozjpeg/cjpeg.c:673), so an explicit `-quality 75`
    /// produces different bytes than no flag at all.
    var cjpegQuality: Int?
}

/// The user-facing quality choice, in the app and as the CLI's `--quality`.
///
/// `String`-raw-valued because the rawValue is the UserDefaults persistence
/// format — renaming a case is a migration, exactly as for `MetadataPolicy`.
///
/// **PNG and GIF deliberately ignore this**, and that is a decision rather
/// than an omission. pngquant's `--quality min-max` is a floor with an abort,
/// not a dial: it exits 99 and writes nothing when it cannot reach `min`
/// (vendor/src/pngquant/pngquant.c:198), which `ShrinkEngine` would surface
/// as a failed shrink — so wiring a high quality to PNG would turn a
/// preference into an error on hard images. gifsicle's `--lossy=N` inverts
/// the axis (0 is lossless, higher is worse) and GIF output is lossless
/// today. Both want their own design; neither belongs in a first pass.
/// Declared worst-to-best: `allCases` *is* the Settings picker's option list
/// (the rows iterate it directly), so this order is the on-screen order.
enum QualityLevel: String, CaseIterable, Sendable {
    case low
    /// Spelled `standard` rather than `default` because `default` is a
    /// reserved word. This is the shipped behaviour, unchanged.
    case standard
    case high

    var settings: QualitySettings {
        switch self {
        case .low:
            // Visibly softer on close inspection, materially smaller. 60 is
            // low enough to be worth choosing over `.standard` and high
            // enough to stay clear of the blocking that sets in below ~50.
            QualitySettings(unitScale: 0.60, cwebpScale: 60, cjpegQuality: 60)
        case .standard:
            // Exactly what this app shipped before quality was selectable.
            // `cjpegQuality` is nil, not 75 — see `QualitySettings`.
            QualitySettings(unitScale: 0.80, cwebpScale: 80, cjpegQuality: nil)
        case .high:
            // Deliberately short of 100: every encoder here grows sharply in
            // the last few points for no visible return, and a "High" that
            // routinely produced files larger than the input would read as
            // broken rather than careful.
            QualitySettings(unitScale: 0.92, cwebpScale: 92, cjpegQuality: 90)
        }
    }
}
