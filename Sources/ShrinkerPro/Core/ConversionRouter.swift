import Foundation

/// The raster family a supported input file belongs to. Deliberately
/// narrower than "file extension": `.heic` and `.heif` both map to
/// `.heic`, since they decode identically through ImageIO and share one
/// `ConversionRules` field. SVG and GIF are not represented here — they
/// never reach `ConversionRouter` at all (see `ShrinkEngine.shrink`).
enum NativeFormat: Equatable, Sendable {
    case png, jpeg, webp, avif, heic

    init?(extension ext: String) {
        switch ext {
        case "png": self = .png
        case "jpg", "jpeg": self = .jpeg
        case "webp": self = .webp
        case "avif": self = .avif
        case "heic", "heif": self = .heic
        default: return nil
        }
    }
}

/// A lossless carrier format used only to hand pixels from ImageIO's
/// decoder to a vendored CLI encoder that cannot read the original input
/// itself. Never the final output format, never user-visible.
enum IntermediateFormat: Equatable, Sendable {
    /// cjpeg (built with `PNG_SUPPORTED=FALSE`, see build-compressors.sh)
    /// reads only BMP, GIF, PPM/PGM, or Targa. ImageIO's own BMP writer
    /// emits a BITMAPV4/V5 header cjpeg's reader rejects ("bad header
    /// length", verified against the vendored binary), and GIF is
    /// palette-quantized — a real quality loss ahead of a lossy JPEG
    /// encode. TGA is full-color, ImageIO writes it losslessly, and
    /// cjpeg's rdtarga.c reads it back exactly — verified end-to-end
    /// against the vendored binary.
    case tga
    /// cwebp reads PNG natively; ImageIO writes it losslessly. Used only
    /// when the source is HEIC or AVIF, which cwebp cannot read at all.
    ///
    /// The spec names TIFF for this role ("cwebp accepts PNG, JPEG, TIFF
    /// and WebP input"), but that's libwebp's *general* capability, not
    /// this vendored binary's: `scripts/build-compressors.sh` builds
    /// cwebp's PNG and JPEG input decoding from source (comment there:
    /// "cwebp needs PNG and JPEG *input* decoding ... which pulls in
    /// libpng and libjpeg") and never mentions libtiff at all — no TIFF
    /// support is built in. Verified directly: handing the vendored
    /// cwebp an ImageIO-written TIFF fails with
    /// `TIFF support not compiled. Please install the libtiff
    /// development package before building.` PNG has no such gap (cwebp
    /// reads it as a first-class input, same as a same-format PNG→WebP
    /// conversion already does) and round-trips full color/alpha exactly
    /// as losslessly, so it's the intermediate used here instead.
    case png

    /// ImageIO type identifier to encode the intermediate as.
    var utType: String {
        switch self {
        case .tga: return "com.truevision.tga-image"
        case .png: return "public.png"
        }
    }

    var fileExtension: String {
        switch self {
        case .tga: return "tga"
        case .png: return "png"
        }
    }
}

/// The destination formats reachable by `ConversionRoute.direct` — decode
/// the input and encode straight to this format, no intermediate. A
/// strict subset of `ConversionFormat`: it excludes `.jpeg`, because cjpeg
/// cannot read any of PNG/WebP/AVIF/HEIC directly (see `IntermediateFormat
/// .tga`'s doc comment), so a JPEG target can never take this path — every
/// route to JPEG goes through `RelayedFormat` below instead. Only ImageIO
/// (AVIF) and cwebp (WebP, reading PNG/JPEG/WebP natively) qualify.
///
/// Not named `DirectFormat`: that reads as "the format is direct", which
/// says nothing; this is the *target* of the direct route, hence the
/// `Target` suffix, matching the `target:` label on `ConversionRoute
/// .direct` itself.
enum DirectTarget: String, CaseIterable, Equatable, Sendable {
    case webp
    case avif
}

/// The destination formats reachable only by `ConversionRoute
/// .viaIntermediate` — decode to a lossless carrier first (see
/// `IntermediateFormat`), then hand that to the destination encoder. A
/// strict subset of `ConversionFormat`: it excludes `.avif`, because
/// ImageIO decodes every supported input directly, so an AVIF target
/// never needs a carrier — every route to AVIF goes through
/// `DirectTarget` above instead. cjpeg (any non-JPEG source) and cwebp
/// (a HEIC/AVIF source) are the two encoders that ever need one.
///
/// Deliberately not called `IntermediateFormat` or a variant of it: that
/// name is already taken by the *carrier's* own format (TGA/PNG above) —
/// reusing it for the *destination* format would invite mixing up "what
/// the intermediate file is encoded as" with "what the whole conversion
/// is ultimately headed towards". "Relayed" names the destination's
/// relationship to that carrier instead: it arrives by being relayed
/// through it, rather than being decoded straight into it.
enum RelayedTarget: String, CaseIterable, Equatable, Sendable {
    case jpeg
    case webp
}

/// The compression pipeline `ConversionRouter.route` decided on for one
/// file, independent of how it gets carried out. Kept separate from the
/// `Compressor` construction in `ShrinkEngine` so the routing *decision* —
/// the part with real logic and edge cases — is testable as a pure
/// function, with no helper binaries, no temp files, no ImageIO calls.
enum ConversionRoute: Equatable {
    /// Run the format's own same-container optimiser: pngquant for PNG,
    /// cjpeg for JPEG, cwebp for WebP, or an ImageIO decode+re-encode for
    /// AVIF/HEIC (there is no dedicated re-optimiser for either — ImageIO
    /// *is* the encoder, same as it would be for a real conversion).
    case sameFormat(NativeFormat)
    /// Decode the input and encode straight to `target`, no intermediate.
    /// Reachable only when the destination encoder can read the source
    /// natively: ImageIO decodes every supported input for an AVIF
    /// target, and cwebp reads PNG/JPEG/WebP directly for a WebP target.
    /// `target` is a `DirectTarget`, not the general `ConversionFormat` —
    /// there is no `.jpeg` case to consider here at all, the same way
    /// there is no `.keep` case to consider (`.keep` is resolved before a
    /// route is ever computed — see
    /// `ConversionRouter.route(native:rule:ConversionTarget)`).
    case direct(target: DirectTarget)
    /// Decode to a lossless intermediate first, then hand that to the
    /// destination encoder. Needed whenever the destination encoder can't
    /// read the source format at all: cjpeg for any non-JPEG source, and
    /// cwebp for a HEIC/AVIF source. `target` is a `RelayedTarget` — there
    /// is no `.avif` case to consider here at all.
    case viaIntermediate(target: RelayedTarget, intermediate: IntermediateFormat)
}

/// Decides *how* to compress a file of a given native format under a given
/// conversion rule. Pure and IO-free by design: no file paths, no helper
/// binaries, no ImageIO — so every combination of input format × rule is
/// cheap to enumerate and check without touching a real image or process.
/// `ShrinkEngine` is the only caller, and turns the result into an actual
/// `Compressor` by supplying the binaries/quality this function has no
/// business knowing about.
enum ConversionRouter {

    /// For every input format whose user-facing rule may legitimately be
    /// "keep" — PNG, JPEG, WebP, AVIF (see `ConversionTarget`). HEIC/HEIF
    /// has no such rule at all and calls the `ConversionFormat` overload
    /// below directly.
    static func route(native: NativeFormat, rule: ConversionTarget) -> ConversionRoute {
        // .keep never needs a target at all — resolve it before anything
        // else so nothing downstream of this point ever has to consider
        // .keep again. `conversionFormat` is nil for exactly that one
        // case, so there is no case left here to mishandle.
        guard let format = rule.conversionFormat else {
            return .sameFormat(native)
        }
        return route(native: native, rule: format)
    }

    /// The routing decision once "keep" has been ruled out (or, for HEIC,
    /// was never on the table in the first place). `rule` is a
    /// `ConversionFormat`, which has no `.keep` case to write — the type
    /// itself is the guarantee, not a runtime check.
    static func route(native: NativeFormat, rule: ConversionFormat) -> ConversionRoute {
        // Same-format conversion is still compression (spec): an explicit
        // rule naming the input's own format (JPEG→JPEG, WebP→WebP,
        // AVIF→AVIF) must take the same fast path as .keep, not a
        // decode/re-encode round trip. PNG and HEIC/HEIF can't hit this —
        // neither is ever native alongside a matching same-format rule
        // here (PNG has no same-format rule at all; HEIC's own format
        // isn't one of `ConversionFormat`'s cases) — so they always fall
        // through to `convert(native:to:)` below.
        switch (native, rule) {
        case (.jpeg, .jpeg), (.webp, .webp), (.avif, .avif):
            return .sameFormat(native)
        default:
            return convert(native: native, to: rule)
        }
    }

    /// The actual conversion decision, once same-format compression has
    /// been ruled out by `route(native:rule:ConversionFormat)` above.
    /// Kept as its own `static` function (rather than inlined into
    /// `route`) specifically so `ConversionRouterTests` can call the WebP
    /// branch below directly for `native: .webp` — a combination `route`
    /// itself never reaches, because it's already short-circuited as
    /// `.sameFormat` above. That makes the branch's correctness (not just
    /// its absence of a crash) an observable, tested fact rather than
    /// something inferred from "the crash was never seen".
    static func convert(native: NativeFormat, to rule: ConversionFormat) -> ConversionRoute {
        switch rule {
        case .avif:
            // ImageIO decodes every supported input format directly, so
            // there is never an intermediate step for an AVIF target.
            return .direct(target: .avif)

        case .jpeg:
            // cjpeg cannot read PNG, WebP, AVIF, or HEIC (see
            // IntermediateFormat.tga's doc comment) — every non-JPEG
            // source needs the TGA intermediate. (A JPEG source targeting
            // JPEG is handled by the same-format short-circuit above and
            // never reaches here.)
            return .viaIntermediate(target: .jpeg, intermediate: .tga)

        case .webp:
            switch native {
            case .png, .jpeg, .webp:
                // cwebp reads all three directly — including WebP itself.
                // A WebP source normally never reaches here (the
                // same-format short-circuit above already returns
                // `.sameFormat(.webp)` for it), but if it ever did, this
                // is the genuinely correct answer, not an impossible
                // state: cwebp reads WebP natively the same as PNG/JPEG.
                return .direct(target: .webp)
            case .avif, .heic:
                // cwebp cannot read either directly.
                return .viaIntermediate(target: .webp, intermediate: .png)
            }
        }
    }
}
