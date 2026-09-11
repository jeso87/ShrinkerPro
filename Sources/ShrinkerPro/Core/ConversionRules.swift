import Foundation

/// What a given input format should become, for every input format that is
/// allowed to stay exactly as it is. Same four choices for PNG, JPEG, WebP
/// and AVIF, per the spec: "Keep original" plus the three targets
/// macOS/the vendored tools can actually produce.
///
/// HEIC/HEIF is deliberately not one of those inputs — see `ConversionFormat`.
///
/// `rawValue` is the UserDefaults persistence format — see `Settings` —
/// so renaming a case here is a migration, not a free rename.
enum ConversionTarget: String, CaseIterable, Equatable, Sendable {
    case keep
    case jpeg
    case webp
    case avif
}

/// A real destination format — deliberately narrower than `ConversionTarget`
/// by exactly one case: there is no `.keep`. HEIC/HEIF is the one input
/// format that must always convert (spec: it's a capture format, re-encoding
/// it to HEIC saves little, and it stays a file many apps and sites can't
/// open), so its rule is typed so "keep" cannot be selected, stored, or
/// routed — not merely defaulted away from.
///
/// `ConversionRouter.convert(native:to:)` takes this type as the rule to
/// convert to, once "not keeping" has been decided — `case .keep` should
/// not even be something the compiler lets you write by that point. Its
/// result narrows further still: `ConversionRoute.direct`/
/// `.viaIntermediate` each carry `DirectTarget`/`RelayedTarget` (see
/// `ConversionRouter.swift`), not this type directly, since `.direct` can
/// never target `.jpeg` and `.viaIntermediate` can never target `.avif`.
///
/// `rawValue` is the UserDefaults persistence format for `heicConversion` —
/// see `Settings.readFormat`, which is also where a value written before
/// this type existed (a stored `"keep"`, from when HEIC still offered it)
/// is migrated forward rather than crashing.
enum ConversionFormat: String, CaseIterable, Equatable, Sendable {
    case jpeg
    case webp
    case avif
}

extension ConversionTarget {
    /// This target's real destination format, or `nil` for `.keep` — the
    /// one case that isn't a destination at all. `ConversionRouter` uses
    /// this to resolve "not keeping" into a `ConversionFormat` exactly
    /// once, so nothing downstream of that point has to consider `.keep`
    /// again.
    var conversionFormat: ConversionFormat? {
        switch self {
        case .keep: return nil
        case .jpeg: return .jpeg
        case .webp: return .webp
        case .avif: return .avif
        }
    }

    /// Display text for every case except `.keep`, whose row-specific
    /// wording ("Keep PNG", "Keep JPEG", ...) is composed by the caller
    /// instead — see `SettingsView.ConversionRuleRow`.
    var displayName: String {
        switch self {
        case .keep: return "Keep"
        case .jpeg: return "JPEG"
        case .webp: return "WebP"
        case .avif: return "AVIF"
        }
    }
}

extension ConversionFormat {
    var displayName: String {
        switch self {
        case .jpeg: return "JPEG"
        case .webp: return "WebP"
        case .avif: return "AVIF"
        }
    }
}

/// One conversion rule per convertible input format. SVG and GIF have no
/// field here — they are never candidates for conversion (see the spec's
/// "Conversion rules" section) and `ShrinkEngine` never consults this type
/// for them.
///
/// HEIC and HEIF share a single rule (`heic`): the spec's table lists them
/// as one row, and both decode identically through ImageIO.
///
/// `png`/`jpeg`/`webp`/`avif` default to `.keep`, so a bare
/// `ConversionRules()` reproduces pre-conversion-feature behavior exactly
/// for them — nothing changes container. `heic` has no `.keep` to default
/// to (see `ConversionFormat`) and defaults directly to `.jpeg`, the spec's
/// one opinionated default — there is no neutral value left for
/// `Settings.outputSettings` to override the way it can for every other
/// format.
struct ConversionRules: Equatable, Sendable {
    var png: ConversionTarget = .keep
    var jpeg: ConversionTarget = .keep
    var heic: ConversionFormat = .jpeg
    var webp: ConversionTarget = .keep
    var avif: ConversionTarget = .keep
}

extension ConversionFormat {
    /// This rule's equivalent in the router's own, wider vocabulary. The
    /// widening is one-way: `TargetFormat` has a `.png` case that no
    /// persisted rule can produce (see `SessionFormat`).
    var targetFormat: TargetFormat {
        switch self {
        case .jpeg: return .jpeg
        case .webp: return .webp
        case .avif: return .avif
        }
    }
}
