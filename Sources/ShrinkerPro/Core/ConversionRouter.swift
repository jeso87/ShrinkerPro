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

/// Every format the router can be asked to produce.
///
/// Deliberately wider than `ConversionFormat`, which is *persisted* and must
/// stay exactly the three options the Settings rows offer. `.png` is
/// reachable only through `SessionFormat`, so it lives here rather than
/// being added to a type whose `allCases` drives a picker.
///
/// This is the router's own vocabulary: both a stored rule and a session
/// override map into it, and nothing downstream has to know which of the two
/// it came from.
enum TargetFormat: String, CaseIterable, Equatable, Sendable {
    case jpeg
    case webp
    case avif
    case png
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
    /// Reachable only through the session override (`SessionFormat.png`);
    /// PNG is not one of the persisted per-format rules. ImageIO decodes to
    /// a PNG intermediate and `pngquant` compresses it, reusing the existing
    /// relay rather than adding a fifth encoder. A PNG *source* targeting
    /// PNG short-circuits to `.sameFormat(.png)` long before this.
    case png
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

/// Everything about one file, beyond its own format and the rule that
/// applies to it, that can change which pipeline it takes.
///
/// Both fields exist because the three vendored CLI encoders are trusted to
/// read the user's original file directly only when they need no help with
/// it. When they do, the fix is the same in every case: send the pixels
/// through ImageIO first, which is the app's only decoder and therefore the
/// only thing that can rotate or re-author metadata.
struct RoutingContext: Equatable, Sendable {

    /// `false` when the source declares an orientation other than "up".
    ///
    /// Such a file's pixels **must** pass through an ImageIO decode before
    /// any encoder sees them, because that is where the rotation is baked in
    /// (see `ImageMetadata.applyingOrientation`). Preserving the tag instead
    /// is not an option: the TGA and PNG intermediates have no orientation
    /// field to carry one, so it cannot fix HEIC → JPEG — the default rule,
    /// and the case users actually reported.
    var isUpright: Bool = true

    /// What the user asked to keep. Only `.copyright` changes routing:
    /// cwebp's `-metadata` flag can express "all" and "none" but has no
    /// setting for "just the rights tags", so that one policy has to be
    /// applied by authoring the intermediate rather than by flag.
    var policy: MetadataPolicy = .all

    static let `default` = RoutingContext()
}

/// Decides *how* to compress a file of a given native format under a given
/// conversion rule. Pure and IO-free by design: no file paths, no helper
/// binaries, no ImageIO — so every combination of input format × rule ×
/// context is cheap to enumerate and check without touching a real image or
/// process. `ShrinkEngine` is the only caller, and turns the result into an
/// actual `Compressor` by supplying the binaries/quality this function has
/// no business knowing about.
///
/// Note that `context` is read *from the file* by the caller but is not
/// itself IO: orientation arrives here as a plain `Bool`, which is what
/// keeps this type testable by enumeration.
enum ConversionRouter {

    /// For every input format whose user-facing rule may legitimately be
    /// "keep" — PNG, JPEG, WebP, AVIF (see `ConversionTarget`). HEIC/HEIF
    /// has no such rule at all and calls the `ConversionFormat` overload
    /// below directly.
    static func route(
        native: NativeFormat, rule: ConversionTarget, context: RoutingContext = .default
    ) -> ConversionRoute {
        // .keep never needs a target at all — resolve it before anything
        // else so nothing downstream of this point ever has to consider
        // .keep again. `conversionFormat` is nil for exactly that one
        // case, so there is no case left here to mishandle.
        guard let format = rule.conversionFormat else {
            return honouring(.sameFormat(native), context: context)
        }
        return route(native: native, rule: format, context: context)
    }

    /// The routing decision once "keep" has been ruled out (or, for HEIC,
    /// was never on the table in the first place). `rule` is a
    /// `ConversionFormat`, which has no `.keep` case to write — the type
    /// itself is the guarantee, not a runtime check.
    static func route(
        native: NativeFormat, rule: ConversionFormat, context: RoutingContext = .default
    ) -> ConversionRoute {
        route(native: native, target: rule.targetFormat, context: context)
    }

    /// The session override's entry point, and the one place `.png` can
    /// arrive as a target. Identical logic to the stored-rule overloads
    /// above — a session override is not a different kind of conversion,
    /// only a different source of the same decision.
    static func route(
        native: NativeFormat, target: TargetFormat, context: RoutingContext = .default
    ) -> ConversionRoute {
        // Same-format conversion is still compression (spec): an explicit
        // target naming the input's own format (JPEG→JPEG, WebP→WebP,
        // AVIF→AVIF, PNG→PNG) must take the same fast path as .keep, not a
        // decode/re-encode round trip. HEIC/HEIF can't hit this — its own
        // format isn't one of `TargetFormat`'s cases — so it always falls
        // through to `convert(native:to:)` below.
        switch (native, target) {
        case (.jpeg, .jpeg), (.webp, .webp), (.avif, .avif), (.png, .png):
            return honouring(.sameFormat(native), context: context)
        default:
            return convert(native: native, to: target, context: context)
        }
    }

    /// The actual conversion decision, once same-format compression has
    /// been ruled out by `route(native:target:)` above.
    ///
    /// Kept as its own `static` function (rather than inlined into `route`)
    /// specifically so `ConversionRouterTests` can call the WebP branch
    /// below directly for `native: .webp` — a combination `route` itself
    /// never reaches, because it's already short-circuited as `.sameFormat`
    /// above. That makes the branch's correctness (not just its absence of a
    /// crash) an observable, tested fact rather than something inferred from
    /// "the crash was never seen".
    static func convert(
        native: NativeFormat, to target: TargetFormat, context: RoutingContext = .default
    ) -> ConversionRoute {
        let route: ConversionRoute
        switch target {
        case .avif:
            // ImageIO decodes every supported input format directly, so
            // there is never an intermediate step for an AVIF target.
            route = .direct(target: .avif)

        case .jpeg:
            // cjpeg cannot read PNG, WebP, AVIF, or HEIC (see
            // IntermediateFormat.tga's doc comment) — every non-JPEG
            // source needs the TGA intermediate. (A JPEG source targeting
            // JPEG is handled by the same-format short-circuit above and
            // never reaches here.)
            route = .viaIntermediate(target: .jpeg, intermediate: .tga)

        case .png:
            // pngquant reads nothing but PNG, so every non-PNG source
            // decodes to a PNG intermediate first. (A PNG source targeting
            // PNG is handled by the same-format short-circuit above.)
            //
            // Worth knowing rather than discovering: PNG is lossless, so a
            // photograph converted this way routinely comes out several
            // times larger than the JPEG or HEIC it came from. That is
            // inherent to the request, not a fault in this route — the UI
            // says so where the target is chosen.
            route = .viaIntermediate(target: .png, intermediate: .png)

        case .webp:
            switch native {
            case .png, .jpeg, .webp:
                // cwebp reads all three directly — including WebP itself.
                // A WebP source normally never reaches here (the
                // same-format short-circuit above already returns
                // `.sameFormat(.webp)` for it), but if it ever did, this
                // is the genuinely correct answer, not an impossible
                // state: cwebp reads WebP natively the same as PNG/JPEG.
                route = .direct(target: .webp)
            case .avif, .heic:
                // cwebp cannot read either directly.
                route = .viaIntermediate(target: .webp, intermediate: .png)
            }
        }
        return honouring(route, context: context)
    }

    /// Rewrites a route that would point a CLI encoder straight at the
    /// user's file, in the cases where doing so would produce the wrong
    /// result. Every rewrite substitutes the relayed equivalent of the same
    /// destination, so the *output format* is never changed here — only the
    /// path taken to it.
    ///
    /// Applied at the end of every route decision rather than at each
    /// `return`, so a route added later cannot forget it.
    private static func honouring(
        _ route: ConversionRoute, context: RoutingContext
    ) -> ConversionRoute {
        switch route {
        case .sameFormat(let native):
            switch native {
            case .jpeg:
                // cjpeg cannot rotate. The TGA detour costs no extra
                // generational loss: cjpeg already fully decodes and
                // re-encodes, and TGA is lossless.
                return context.isUpright
                    ? route : .viaIntermediate(target: .jpeg, intermediate: .tga)
            case .png:
                return context.isUpright
                    ? route : .viaIntermediate(target: .png, intermediate: .png)
            case .webp:
                return cwebpNeedsNoHelp(context)
                    ? route : .viaIntermediate(target: .webp, intermediate: .png)
            case .avif, .heic:
                // Already ImageIO end to end, which is where the rotation
                // and the metadata are applied. Nothing to reroute.
                return route
            }

        case .direct(let target):
            switch target {
            case .avif:
                return route
            case .webp:
                return cwebpNeedsNoHelp(context)
                    ? route : .viaIntermediate(target: .webp, intermediate: .png)
            }

        case .viaIntermediate:
            // Already going through ImageIO, which is the fix itself.
            return route
        }
    }

    /// Whether cwebp can be pointed at the user's original file.
    ///
    /// It can, on both counts, only when it needs no help: the pixels are
    /// already upright (cwebp cannot rotate), and the policy is one its
    /// `-metadata` flag can state exactly. That flag takes `all` or `none`
    /// and has nothing in between, so `.copyright` has to be applied by
    /// authoring the PNG intermediate with exactly the tags to keep and then
    /// passing `-metadata all`.
    ///
    /// WebP is the one output format with no post-pass available to correct
    /// any of this afterwards: ImageIO cannot write WebP at all, so whatever
    /// cwebp emits is final.
    private static func cwebpNeedsNoHelp(_ context: RoutingContext) -> Bool {
        context.isUpright && context.policy != .copyright
    }
}

extension ConversionRoute {
    /// Whether the finished output still needs its metadata written for it.
    ///
    /// True exactly when the encoder producing the final bytes is one of the
    /// vendored CLI tools whose output ImageIO *can* still rewrite losslessly
    /// — cjpeg and pngquant. Neither can be told what metadata to emit:
    /// cjpeg copies every marker or none depending only on its input format,
    /// and pngquant keeps whatever chunks it keeps. So the policy is applied
    /// afterwards instead, by `ImageMetadata.rewriteMetadata`.
    ///
    /// False for ImageIO's own outputs (already written correctly at encode
    /// time) and for cwebp, whose output ImageIO cannot open for writing at
    /// all — WebP is handled by the `-metadata` flag and the intermediate.
    var needsMetadataPostPass: Bool {
        switch self {
        case .sameFormat(let native):
            return native == .jpeg || native == .png
        case .direct:
            return false
        case .viaIntermediate(let target, _):
            return target == .jpeg || target == .png
        }
    }
}
