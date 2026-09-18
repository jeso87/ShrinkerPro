import Foundation
import UniformTypeIdentifiers

struct ShrinkResult: Equatable {
    let input: URL
    let output: URL
    let originalBytes: Int
    let shrunkBytes: Int

    /// Upstream formula: Math.round((100 / sizeBefore) * (sizeBefore - sizeAfter))
    var savedPercent: Int {
        guard originalBytes > 0 else { return 0 }
        let ratio = (100.0 / Double(originalBytes)) * Double(originalBytes - shrunkBytes)
        return Int(ratio.rounded())
    }
}

/// Everything `ShrinkEngine.shrink` needs to know about how one file will be
/// handled, decided before a single byte is written — and now handed to the
/// caller, so "where would this land?" can be answered without landing it.
///
/// Only `input` and `destination` are a caller's business. The routing fields
/// below are the engine's own: a caller that builds one by hand can hand the
/// engine a route that contradicts its own destination, so get a plan from
/// `ShrinkEngine.plan(_:settings:)` and redirect it with `writing(to:)` rather
/// than constructing one. They are `internal` rather than `fileprivate` so
/// that a test *can* build one directly when it needs to: `@testable import`
/// reaches `internal` but never `fileprivate`. Nothing builds one by hand
/// today — every test here goes through `ShrinkEngine.plan(_:settings:)` and
/// `writing(to:)` — but the overwrite guard that follows needs a plan it can
/// stand up without an engine behind it.
///
/// `Sendable` because a plan is decided where the user can be asked about it
/// and executed somewhere else — see `ShrinkEngine`'s own conformance below.
struct ShrinkPlan: Sendable {
    let input: URL
    /// Where this will be written. Computed by `OutputPathResolver.destination`,
    /// which creates nothing — the directory is made in `shrink(_:)`.
    let destination: URL

    let compressor: Compressor
    /// `nil` means "keep the input's own extension" — same-format
    /// compression — and a non-nil value is the conversion's target
    /// extension that `OutputPathResolver` was given instead.
    let targetExtension: String?
    /// Whether the finished output still needs its metadata written by
    /// ImageIO because the encoder could not.
    let needsMetadataPostPass: Bool
    /// Whether the source declared an orientation now baked into the pixels.
    let wasRotated: Bool
    /// Whether the file comes out in the format it went in as. Deliberately
    /// NOT derived from `targetExtension`: a rotated JPEG is rewritten into a
    /// relayed route that reports a non-nil extension while converting
    /// nothing, and reading "same format" off that is what let the never-grow
    /// guard overwrite rotated originals with larger files.
    let isSameFormat: Bool
    /// What the metadata post-pass is allowed to keep. Carried here because
    /// `shrink(_:)` no longer receives the `OutputSettings` it used to read
    /// this from — a plan has to be the whole of what executing a file needs.
    let metadataPolicy: MetadataPolicy
    /// Whether this file's dimensions are being changed on purpose — scaled
    /// down to the session's max size, cropped to its crop target, or both.
    ///
    /// Read by the never-grow guard below, which it exempts: a resize or a
    /// crop is an explicit instruction about the file's dimensions, so
    /// silently returning the untouched original because the bytes did not
    /// fall would be ignoring what was asked rather than protecting anything.
    ///
    /// Carried on the plan rather than inferred from `targetExtension` or
    /// `isSameFormat`, in keeping with those fields' own warnings: deriving
    /// one property of a route from another is exactly what produced the bug
    /// they document.
    let dimensionsChanged: Bool

    /// The same plan, writing somewhere else. This is how Keep Both is
    /// applied: only the destination moves, so the route, the conversion and
    /// the metadata pass are all carried over exactly as planned.
    func writing(to newDestination: URL) -> ShrinkPlan {
        ShrinkPlan(
            input: input, destination: newDestination, compressor: compressor,
            targetExtension: targetExtension, needsMetadataPostPass: needsMetadataPostPass,
            wasRotated: wasRotated, isSameFormat: isSameFormat, metadataPolicy: metadataPolicy,
            dimensionsChanged: dimensionsChanged
        )
    }
}

/// Dispatches a file to the right compressor by extension and reports the
/// resulting size delta. This is the entry point the UI calls.
final class ShrinkEngine {

    static let supportedExtensions: Set<String> = [
        "svg", "png", "gif", "jpg", "jpeg", "webp", "avif", "heic", "heif",
    ]

    /// The same set as `supportedExtensions`, expressed as UTTypes for
    /// `NSOpenPanel`. Kept adjacent to the extension list because the two must
    /// agree: a type missing here is greyed out in the file picker even though
    /// the engine would happily compress it — which is exactly what happened
    /// when HEIC/WebP/AVIF were added as inputs and only the extension list
    /// was updated. `.avif` has no UTType constant, so it is built from its
    /// identifier; `UTType(filenameExtension:)` would depend on whatever the
    /// running system happens to have registered.
    static let supportedContentTypes: [UTType] = [
        .svg, .png, .gif, .jpeg, .webP, .heic, .heif,
        UTType("public.avif"),
    ].compactMap { $0 }

    private let helperProvider: @Sendable (String) throws -> URL
    private let svgCompressor: SVGCompressor

    /// - Parameters:
    ///   - helperProvider: maps a helper binary name ("cjpeg", "pngquant",
    ///     "gifsicle") to its executable URL, throwing `.helperMissing(name)`
    ///     if it can't. Defaults to `HelperLocator.url(named:)`, which
    ///     resolves `Contents/Helpers/` in the main bundle and performs
    ///     exactly that check; tests inject `vendor/compressors/` directly.
    ///     The closure is throwing (not just `(String) -> URL`) specifically
    ///     so a missing/non-executable helper is a typed `ShrinkError`
    ///     surfaced lazily at the point a format actually needs that helper,
    ///     never an unchecked path that reaches `ProcessRunner` and comes
    ///     back out as a raw Foundation file-not-found error.
    ///   - svgoScriptURL: the ESM-stripped svgo bundle produced by
    ///     `scripts/prepare-svgo.sh`. Defaults to the main bundle's copy.
    ///     A fresh clone that never ran that script has no svgo.jsc.js —
    ///     that case (and any other missing/unreadable script, explicit or
    ///     defaulted) surfaces as `.helperMissing("svgo.jsc.js")`, never a
    ///     raw Foundation file-not-found error escaping from
    ///     `SVGCompressor`'s `String(contentsOf:)`.
    init(
        helperProvider: (@Sendable (String) throws -> URL)? = nil,
        svgoScriptURL: URL? = nil
    ) throws {
        self.helperProvider = helperProvider ?? { name in try HelperLocator.url(named: name) }

        let resolvedScript = svgoScriptURL
            ?? Bundle.main.url(forResource: "svgo.jsc", withExtension: "js")
        guard let script = resolvedScript,
              FileManager.default.isReadableFile(atPath: script.path) else {
            throw ShrinkError.helperMissing("svgo.jsc.js")
        }
        self.svgCompressor = try SVGCompressor(scriptURL: script)
    }

    /// Decides how one file will be handled, and where it would land, without
    /// writing anything or creating any directory.
    ///
    /// The half that can safely be run over a whole drop: a hundred files can
    /// be planned in order to ask which of them would replace something, and
    /// if the answer is "cancel", nothing has appeared on disk.
    func plan(_ input: URL, settings: OutputSettings) throws -> ShrinkPlan {
        let ext = input.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else {
            throw ShrinkError.unsupportedFormat(ext)
        }

        let routing = try routing(for: ext, input: input, settings: settings)
        return ShrinkPlan(
            input: input,
            destination: OutputPathResolver.destination(
                input: input, settings: settings, targetExtension: routing.targetExtension
            ),
            compressor: routing.compressor,
            targetExtension: routing.targetExtension,
            needsMetadataPostPass: routing.needsMetadataPostPass,
            wasRotated: routing.wasRotated,
            isSameFormat: routing.isSameFormat,
            metadataPolicy: settings.metadataPolicy,
            dimensionsChanged: routing.dimensionsChanged
        )
    }

    /// Plan and execute in one call. The shape the CLI and most existing
    /// tests use, and the reason neither had to change.
    func shrink(_ input: URL, settings: OutputSettings) throws -> ShrinkResult {
        try shrink(plan(input, settings: settings))
    }

    /// Compresses `plan.input` into `plan.destination` and reports the size
    /// delta.
    ///
    /// Note: the destination directory is created here, before compression is
    /// attempted below — the same point in the sequence as when
    /// `OutputPathResolver.resolve` created it as a side effect of computing
    /// the path (a faithful port of upstream's `makeDir.sync` placement). So
    /// if compression subsequently throws, an empty destination directory
    /// (e.g. `minified/`) can be left behind on disk. That is upstream's
    /// existing behavior, not a bug introduced here, and is out of scope to
    /// "fix" by adding cleanup.
    func shrink(_ plan: ShrinkPlan) throws -> ShrinkResult {
        let input = plan.input
        let output = plan.destination
        let ext = input.pathExtension.lowercased()

        let originalBytes = try byteCount(of: input)

        // Deferred to here, and no earlier: planning must leave no trace, so
        // the one side effect in path resolution happens once the caller has
        // committed to actually writing this file.
        try OutputPathResolver.prepareDirectory(for: output)

        // No compressor is ever handed `output` as its write target.
        //
        // With `.min` suffix and `minified/` subfolder both off, `output`
        // resolves to `input` — compression runs over the user's original,
        // with no second copy anywhere. Several of the vendored tools
        // truncate their write target *before* they have finished
        // validating the input, so a corrupt-but-precious file (a partial
        // download, damaged media) would be destroyed by a compression
        // that then reports failure:
        //
        //   - cjpeg opens `-outfile` with "wb" before libjpeg decodes
        //     anything. Truncated 22892-byte JPEG in place -> 0 bytes,
        //     exit 1.
        //   - gifsicle's `output_frames()` is gated on `error_count == 0`
        //     (vendor/src/gifsicle/src/gifsicle.c:2225), but read errors
        //     are rolled back before that gate is ever reached --
        //     `if (!no_ignore_errors) error_count = old_error_count;` at
        //     gifsicle.c:746 -- so the gate sees zero, the target is
        //     truncated, and only afterwards is the buffered error
        //     re-raised as exit status 1. Truncated 61156-byte GIF in
        //     place -> 835 bytes, exit 1.
        //   - pngquant does write to a private tempname and rename on
        //     success today (checked: truncated PNG in place, exit 25,
        //     file unchanged), but that is an observation about the
        //     current binary, not a contract it owes us.
        //
        // Rather than audit each tool -- an audit that has already been
        // gotten wrong twice for gifsicle by reading only the gate and not
        // the rollback 1400 lines earlier -- the invariant lives here:
        // every compressor writes to a scratch file this engine owns and
        // can throw away, and only a run that exited cleanly *and*
        // produced non-empty data is promoted onto `output`. A fifth
        // format added later inherits that for free, and JPEGCompressor no
        // longer needs private staging of its own.
        //
        // The scratch file is a sibling of `output` so the promotion is a
        // same-volume rename (atomic, and it can't fail halfway for lack
        // of space the way a cross-volume copy could). It carries the
        // *target* extension (== `ext` for same-format compression, the
        // conversion's target extension otherwise) because some tools
        // infer format from it.
        let scratchExtension = plan.targetExtension ?? ext

        // The scratch lives in an item-replacement directory rather than
        // beside `output`. `.itemReplacementDirectory` is guaranteed to be on
        // the same volume as the destination, so promotion is still an atomic
        // same-volume rename — but nothing is ever created inside the user's
        // own folder.
        //
        // It previously WAS a dot-prefixed sibling, which meant briefly
        // creating a hidden file inside whatever directory the user dropped
        // from. In an iCloud Drive folder that hands the file provider
        // something to notice, sync, and then see renamed out from under it,
        // for no benefit. Apple provides this API for exactly this job.
        let replacementDirectory = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: output,
            create: true
        )
        let scratch = replacementDirectory
            .appendingPathComponent("\(UUID().uuidString).\(scratchExtension)")
        defer { try? FileManager.default.removeItem(at: replacementDirectory) }

        try plan.compressor.compress(input: input, output: scratch)

        // Existence alone would be a lie about what got produced: an
        // exit-0 run that wrote an empty file must not overwrite anything.
        guard ((try? byteCount(of: scratch)) ?? 0) > 0 else {
            throw ShrinkError.outputNotWritten(output)
        }

        // cjpeg and pngquant cannot be told what metadata to emit, so the
        // user's policy is applied to their output here instead — copying
        // the already-compressed image data across verbatim rather than
        // re-encoding it, which would throw away the work those tools were
        // run to do. Deliberately placed before promotion: like the
        // compressors above, this only ever touches the scratch file, so a
        // failure here leaves the user's original exactly as it was.
        //
        // `input` is still intact at this point — no compressor has ever
        // been handed it as a write target — so it is safe to read the
        // metadata back out of it even in the in-place case where `output`
        // resolves to `input`.
        if plan.needsMetadataPostPass,
           let utType = ImageMetadata.utType(forOutputExtension: scratchExtension) {
            try ImageMetadata.rewriteMetadata(
                of: scratch,
                takingFrom: input,
                policy: plan.metadataPolicy,
                utType: utType,
                wasRotated: plan.wasRotated,
                workingIn: replacementDirectory
            )
        }

        // Re-measured after the metadata pass, which changes the size: it
        // strips the markers cjpeg copied, or adds the EXIF a relayed
        // encode could not carry. Reporting the pre-pass number would make
        // the saving shown in the UI disagree with the file on disk.
        let shrunkBytes = (try? byteCount(of: scratch)) ?? 0
        guard shrunkBytes > 0 else {
            throw ShrinkError.outputNotWritten(output)
        }

        // Never make a file bigger by compressing it.
        //
        // Re-encoding an already-compressed file at a quality above the one
        // it was stored at inflates it, and the source's original quality is
        // not knowable from the file — so no choice of encoder constant can
        // prevent this, only a check after the fact. Measured against this
        // project's own fixtures before this guard existed, every same-format
        // route grew at `.high`: JPEG 45,784 -> 50,467, WebP 18,828 ->
        // 26,232, AVIF 20,981 -> 24,911. Same-format WebP grew even at
        // `.standard` (18,828 -> 18,864), which predates the quality setting
        // entirely.
        //
        // Scoped to same-format compression whose dimensions are also not
        // changing. A resize or a crop is an instruction about the file's
        // dimensions, not a bet that its bytes will fall, so discarding the
        // result when they don't would hand a full-size image back to someone
        // who asked for a 2000px one — or an uncropped one back to someone who
        // asked for a square — with nothing on screen to say why.
        // `plan.dimensionsChanged` is checked rather than the extension, for
        // the same reason `isSameFormat` is.
        //
        // Worth knowing: a crop touches nearly every file, where a max size
        // only touches files over the cap. Setting one therefore exempts
        // nearly the whole batch, and a ratio-only crop of already
        // well-compressed JPEGs will sometimes write a slightly larger file.
        //
        // Deliberately NOT applied to
        // conversions either. A conversion's growth is the user's own explicit
        // request: PNG is offered precisely so a mixed folder can be
        // flattened to one lossless format, where a photo getting larger is
        // the expected outcome, stated in the README and warned about beside
        // the control. Refusing that would silently ignore what was asked
        // for; refusing this is doing what was asked.
        //
        // `plan.isSameFormat` comes from the *route*, not from whether the
        // output extension changed. Keying it on `targetExtension == nil` was
        // a real bug: `ConversionRouter.honouring` rewrites a same-format
        // route into a relayed one whenever a CLI encoder needs help — a file
        // that is not upright, or WebP under `.copyright` — and every relayed
        // route reports a non-nil extension. So the guard silently stopped
        // applying to every rotated file, which is every portrait phone
        // photo. In place, such a file resolves its output back to the input
        // path, so the unguarded result was written straight over the
        // original: a 2,675-byte rotated JPEG came back as 3,356 bytes while
        // the CLI printed "left alone". See the three regression tests named
        // for it in ShrinkEngineTests.
        //
        // The scratch file is simply not promoted, and `defer` above removes
        // it with the rest of the replacement directory. The result points at
        // `input`, because that is the file the user still has.
        if plan.isSameFormat, !plan.dimensionsChanged, shrunkBytes >= originalBytes {
            return ShrinkResult(
                input: input,
                output: input,
                originalBytes: originalBytes,
                shrunkBytes: originalBytes
            )
        }

        // replaceItemAt is atomic and preserves the destination's metadata
        // when overwriting (the in-place case, and re-runs over an existing
        // `.min` file); a plain move covers a brand-new destination.
        // replaceItemAt returns where the item ACTUALLY ended up, and the docs
        // are explicit that it "may be different from originalItemURL".
        // Discarding it and assuming `output` was a latent bug: on a plain
        // APFS volume the assumption holds, but iCloud Drive is a file
        // provider where node identity is managed differently, and a
        // ShrinkResult pointing at a path the file is not at means Reveal
        // opens Finder on nothing.
        let finalOutput: URL
        if FileManager.default.fileExists(atPath: output.path) {
            finalOutput = try FileManager.default.replaceItemAt(output, withItemAt: scratch) ?? output
        } else {
            try FileManager.default.moveItem(at: scratch, to: output)
            finalOutput = output
        }

        return ShrinkResult(
            input: input,
            output: finalOutput,
            originalBytes: originalBytes,
            shrunkBytes: shrunkBytes
        )
    }

    /// The routing half of a `ShrinkPlan`: everything `shrink` needs to know
    /// about HOW one file will be handled, decided before a single byte is
    /// written and before its destination has been worked out.
    /// `plan(_:settings:)` pairs this with a resolved destination.
    private struct ShrinkPlanRouting {
        let compressor: Compressor
        /// `nil` means "keep the input's own extension" — same-format
        /// compression, unchanged from before the conversion feature — and
        /// a non-nil value is the conversion's target extension for
        /// `OutputPathResolver` to use instead.
        let targetExtension: String?
        /// Whether the finished output still needs its metadata written by
        /// ImageIO because the encoder could not — see
        /// `ConversionRoute.needsMetadataPostPass`.
        let needsMetadataPostPass: Bool
        /// Whether the source declared an orientation that has now been
        /// baked into the pixels. Only used to drop the stale EXIF
        /// dimensions that describe the frame before it was turned.
        let wasRotated: Bool
        /// Whether the file comes out in the format it went in as.
        ///
        /// Deliberately NOT derived from `targetExtension` above, and the two
        /// must not be conflated: a rotated JPEG, or a WebP under
        /// `.copyright`, is rewritten by `ConversionRouter.honouring` into a
        /// relayed route that reports a non-nil extension while converting
        /// nothing. Reading "same format" off that extension is what let the
        /// never-grow guard overwrite rotated originals with larger files.
        let isSameFormat: Bool
        /// Whether this file is being scaled down — see `ShrinkPlan
        /// .dimensionsChanged`, which this becomes.
        let dimensionsChanged: Bool
    }

    /// Decides the compressor pipeline, the output extension, and whether a
    /// metadata pass is still owed, for one input extension.
    ///
    /// SVG and GIF are handled first and unconditionally, before anything
    /// else is even consulted: the spec is explicit that both "never
    /// convert", regardless of what any rule — or the session override —
    /// says, because there is no rule for either of them in the first place
    /// (`ConversionRules` has no `svg` or `gif` field). That same
    /// short-circuit is what exempts them from the session override for
    /// free, and it is why neither is charged the cost of an orientation
    /// read. Everything else goes through `ConversionRouter`, which is where
    /// the actual routing decisions live (and where they're unit-tested,
    /// IO-free).
    private func routing(
        for ext: String, input: URL, settings: OutputSettings
    ) throws -> ShrinkPlanRouting {
        switch ext {
        // Both short-circuit before the router runs, so there is no route to
        // ask — but they are same-format by definition (neither ever
        // converts), and the guard applies to them like anything else.
        case "svg":
            // No max size applies: an SVG is vector, so there is no pixel
            // size to cap. The setting's help text says so.
            return ShrinkPlanRouting(
                compressor: svgCompressor, targetExtension: nil,
                needsMetadataPostPass: false, wasRotated: false, isSameFormat: true,
                dimensionsChanged: false
            )
        case "gif":
            // The one format resized by something other than ImageIO — see
            // `GIFCompressor.maxDimension`. The header read below is paid
            // only when a max size is actually set, so a GIF still costs
            // nothing extra in the ordinary case; it buys the answer to
            // "was this resized?", which the never-grow guard needs and
            // which gifsicle's own silent no-op would not reveal.
            let sizing = sizeDecision(for: input, settings: settings)
            return ShrinkPlanRouting(
                compressor: GIFCompressor(
                    executable: try helperProvider("gifsicle"),
                    resize: sizing.plan
                ),
                targetExtension: nil, needsMetadataPostPass: false, wasRotated: false,
                isSameFormat: true, dimensionsChanged: sizing.changesDimensions
            )
        default:
            break
        }

        guard let native = NativeFormat(extension: ext) else {
            // Unreachable: every extension in `supportedExtensions` other
            // than svg/gif (returned above) has a `NativeFormat`.
            throw ShrinkError.unsupportedFormat(ext)
        }

        // Reading the orientation is a header read, not a decode, so it is
        // cheap enough to do for every raster file before choosing a route.
        // It has to happen here rather than inside a compressor, because
        // whether the file is upright is one of the things that *decides*
        // the route: a rotated file can never be handed straight to a CLI
        // encoder, none of which can rotate.
        let header = ImageMetadata.header(of: input)
        let orientation = header.orientation
        let sizing = sizeDecision(for: header, settings: settings)
        let context = RoutingContext(
            isUpright: orientation == .up,
            policy: settings.metadataPolicy,
            needsPixelRework: sizing.changesDimensions
        )

        // A session override replaces every stored rule at once, for every
        // raster format — that is the whole point of it — so it is checked
        // before the per-format rules are consulted at all. HEIC's rule is a
        // `ConversionFormat` (no `.keep` case — see that type's doc comment)
        // and every other format's is a `ConversionTarget`, so the stored
        // case is computed per-format rather than funneled through one
        // shared `rule` variable that would have to paper over the type
        // difference.
        let route: ConversionRoute
        if let session = settings.sessionFormat {
            route = ConversionRouter.route(
                native: native, target: session.targetFormat, context: context
            )
        } else {
            let rules = settings.conversionRules
            switch native {
            case .png: route = ConversionRouter.route(native: native, rule: rules.png, context: context)
            case .jpeg: route = ConversionRouter.route(native: native, rule: rules.jpeg, context: context)
            case .webp: route = ConversionRouter.route(native: native, rule: rules.webp, context: context)
            case .avif: route = ConversionRouter.route(native: native, rule: rules.avif, context: context)
            case .heic: route = ConversionRouter.route(native: native, rule: rules.heic, context: context)
            }
        }

        return ShrinkPlanRouting(
            compressor: try compressor(
                for: route, policy: settings.metadataPolicy, quality: settings.quality,
                resize: sizing.plan
            ),
            targetExtension: outputExtension(for: route),
            needsMetadataPostPass: route.needsMetadataPostPass,
            wasRotated: orientation != .up,
            isSameFormat: route.isSameFormat(as: native),
            dimensionsChanged: sizing.changesDimensions
        )
    }

    /// What one file's pixels must become, and therefore whether ImageIO has
    /// to be the one to make them.
    ///
    /// One value rather than several so the parts can never disagree: a plan
    /// that says "cropped" while handing a compressor no rectangle, or the
    /// reverse, is not expressible.
    private struct SizeDecision {
        /// The plan to pass along, or `nil` for "leave this file's dimensions
        /// alone" — which covers no crop, no cap, and a file that already
        /// satisfies both. Compressors take `nil` to mean exactly that, so the
        /// untouched case travels as the same value it did before either
        /// setting existed.
        let plan: ResizePlan?

        var changesDimensions: Bool { plan != nil }

        static let none = SizeDecision(plan: nil)
    }

    /// The decision for a file whose header has already been read — every
    /// raster format, where the orientation read was needed anyway.
    ///
    /// The order below **is** the composition rule, written once: crop, then
    /// the crop's own pixel target, then the session's max size. Each step can
    /// only shrink what the last one produced, which is why "never upscale"
    /// needs no clause of its own — it is the shape of the function. See
    /// `2026-09-17-center-crop-design.md` §3.
    ///
    /// A cap of zero or less is treated as no cap rather than rejected: the UI
    /// cannot produce one (`MaxSizeField` maps blank and `0` to `nil`) and the
    /// CLI refuses one at parse time, so this is a floor under a value that
    /// should never arrive, not a second opinion about what is valid.
    private func sizeDecision(
        for header: ImageMetadata.Header, settings: OutputSettings
    ) -> SizeDecision {
        let crop = settings.cropTarget
        let cap = settings.maxDimension.flatMap { $0 > 0 ? $0 : nil }

        // Off must cost nothing: with neither set, no size is even looked at.
        guard crop != nil || cap != nil,
              let pixelSize = header.pixelSize,
              pixelSize.width >= 1, pixelSize.height >= 1
        else { return .none }

        let source = PixelSize(
            width: Int(pixelSize.width.rounded()),
            height: Int(pixelSize.height.rounded())
        )

        // 1. The shape. A `nil` aspect keeps the source's own, which is the
        //    max-size-only case and returns the whole frame.
        let aspect = crop?.aspect
        let rect = CropGeometry.centeredCrop(in: source, aspect: aspect)
        let cropped = PixelSize(width: Int(rect.width), height: Int(rect.height))

        // 2. The crop's own pixel target, in `.pixels` mode only, and only
        //    downwards. An 800×600 source asked for 1200×1200 comes out
        //    600×600 — the cropped size — not 1200×1200. Comparing the widths
        //    alone is enough, because the crop already has the target's
        //    aspect; the heights can differ only by the pixel that rounding
        //    moved.
        var output = cropped
        if let exact = crop?.exactSize, cropped.width > exact.width {
            // Snapped to the requested numbers rather than multiplied out, so
            // 1200 means 1200 and not 1199.
            output = exact
        }

        // 3. The session's max size, over whatever is left — but only when
        //    the crop has not already stated an exact size.
        //
        //    A cap and a pixel crop are two answers to one question. The crop
        //    is the more specific of them, and there is nothing a cap could
        //    add to it that typing smaller numbers into the crop would not say
        //    better, so the cap can only contradict it. Composing them meant
        //    "Crop 1200×1200, Max 500px" quietly writing 500×500 files, which
        //    needed a warning in the window to be survivable — a warning about
        //    two controls fighting, which is a sign that one of them should
        //    not have been there.
        //
        //    A ratio crop is the opposite case: it says nothing about size, so
        //    the cap is the only thing sizing the result and composes with it
        //    exactly as it did before cropping existed. Both front ends say so
        //    in their own way — the window disables the field, and `--crop
        //    WxH` with `--max-size` is refused at parse time.
        if crop?.exactSize == nil, let cap, output.longestSide > cap {
            let scale = Double(cap) / Double(output.longestSide)
            output = PixelSize(
                width: max(1, Int((Double(output.width) * scale).rounded())),
                height: max(1, Int((Double(output.height) * scale).rounded()))
            )
        }

        // 4. Nothing to do. A file already the right shape and already inside
        //    the cap takes the route it took before either setting existed —
        //    the same exemption a file whose longest side equals the cap got,
        //    for the same reason: re-encoding it at its own size costs quality
        //    for no change in dimensions.
        guard output != source else { return .none }

        return SizeDecision(plan: ResizePlan(
            sourceSize: source, aspect: aspect, outputSize: output
        ))
    }

    /// The decision for a file whose header has *not* been read — GIF, which
    /// short-circuits the router and pays no header read of its own.
    ///
    /// The `guard` is what keeps that true when both features are off: with
    /// neither set, no `CGImageSource` is opened and a GIF costs exactly what
    /// it always cost.
    private func sizeDecision(for input: URL, settings: OutputSettings) -> SizeDecision {
        guard settings.maxDimension != nil || settings.cropTarget != nil else { return .none }
        return sizeDecision(for: ImageMetadata.header(of: input), settings: settings)
    }

    /// Turns a routing decision into an actual `Compressor`, supplying the
    /// helper binaries and the resolved quality `ConversionRouter` has no
    /// business knowing about. `.direct(target:)` and
    /// `.viaIntermediate(target:)` carry `DirectTarget`/`RelayedTarget`
    /// rather than the general `ConversionFormat` (see `ConversionRouter
    /// .swift`), so the switches below are already exhaustive over exactly
    /// the combinations the router can produce — there is no `.jpeg` case
    /// to handle under `.direct`, and no `.avif` case under
    /// `.viaIntermediate`, because those types don't have them. Nothing
    /// left here for a `preconditionFailure` to stand in for.
    /// `PNGCompressor` and `GIFCompressor` are constructed without a quality
    /// anywhere below, and that is deliberate — see `QualityLevel`. pngquant's
    /// `--quality` is a floor with an abort rather than a dial, and gifsicle's
    /// `--lossy` inverts the axis against output that is lossless today.
    /// `resize` is `nil` for every file whose dimensions are not changing,
    /// which keeps the decode on those files byte-for-byte the one they got
    /// before the max size existed. Where it is non-nil it reaches ImageIO —
    /// directly, or through the relay's carrier — because ImageIO is the only
    /// component here that can resize or crop at all. pngquant, cjpeg and
    /// cwebp never see it.
    private func compressor(
        for route: ConversionRoute, policy: MetadataPolicy, quality: QualitySettings,
        resize: ResizePlan?
    ) throws -> Compressor {
        switch route {
        case .sameFormat(let native):
            switch native {
            case .png:
                return PNGCompressor(executable: try helperProvider("pngquant"))
            case .jpeg:
                return JPEGCompressor(
                    executable: try helperProvider("cjpeg"), quality: quality.cjpegQuality
                )
            case .webp:
                return WebPCompressor(
                    executable: try helperProvider("cwebp"), policy: policy, quality: quality.cwebpScale
                )
            case .avif:
                return ImageIOCompressor(
                    utType: RasterUTType.avif, quality: quality.unitScale, policy: policy,
                    resize: resize
                )
            case .heic:
                return ImageIOCompressor(
                    utType: RasterUTType.heic, quality: quality.unitScale, policy: policy,
                    resize: resize
                )
            }

        case .direct(let target):
            switch target {
            case .avif:
                return ImageIOCompressor(
                    utType: RasterUTType.avif, quality: quality.unitScale, policy: policy,
                    resize: resize
                )
            case .webp:
                return WebPCompressor(
                    executable: try helperProvider("cwebp"), policy: policy, quality: quality.cwebpScale
                )
            }

        case .viaIntermediate(let target, let intermediate):
            // Quality is applied to the DOWNSTREAM encoder only. The
            // intermediate stays lossless — see
            // `IntermediateConversionCompressor`.
            switch target {
            case .jpeg:
                return IntermediateConversionCompressor(
                    intermediate: intermediate,
                    downstream: JPEGCompressor(
                        executable: try helperProvider("cjpeg"), quality: quality.cjpegQuality
                    ),
                    policy: policy,
                    resize: resize
                )
            case .webp:
                return IntermediateConversionCompressor(
                    intermediate: intermediate,
                    downstream: WebPCompressor(
                        executable: try helperProvider("cwebp"), policy: policy, quality: quality.cwebpScale
                    ),
                    policy: policy,
                    resize: resize
                )
            case .png:
                return IntermediateConversionCompressor(
                    intermediate: intermediate,
                    downstream: PNGCompressor(executable: try helperProvider("pngquant")),
                    policy: policy,
                    resize: resize
                )
            }
        }
    }

    /// `nil` means "keep the input's own extension" (same-format
    /// compression); otherwise the extension `OutputPathResolver` should
    /// use for the converted output instead of the input's.
    ///
    /// `.direct`'s target is a `DirectTarget` and `.viaIntermediate`'s is a
    /// `RelayedTarget` — two different types, each missing the one case
    /// the other route can't produce — so they can no longer be combined
    /// into a single pattern the way a shared `ConversionFormat` allowed;
    /// each gets its own small switch instead.
    private func outputExtension(for route: ConversionRoute) -> String? {
        switch route {
        case .sameFormat:
            return nil
        case .direct(let target):
            switch target {
            case .webp: return "webp"
            case .avif: return "avif"
            }
        case .viaIntermediate(let target, _):
            switch target {
            case .jpeg: return "jpg"
            case .webp: return "webp"
            case .png: return "png"
            }
        }
    }

    /// The size of the file this URL names — following a symlink to whatever
    /// it points at, rather than measuring the link itself.
    ///
    /// `.fileSizeKey` on a symlink reports the link's own size, which is a
    /// hundred-odd bytes of stored path. That made `originalBytes` nonsense
    /// for any symlinked input, and once the never-grow guard existed it
    /// became worse than nonsense: the compressed result is always larger
    /// than 103 bytes, so the guard declined every symlinked file and
    /// nothing was written at all. Measured: a link to a 244,413-byte PNG
    /// reported 103 bytes and produced no output.
    ///
    /// Resolution is for *measurement only*. The engine still writes to the
    /// `output` computed from the original URL — redirecting writes through
    /// the resolved path would change where a symlinked in-place run lands,
    /// which is a far larger behavioural change than the bug being fixed.
    private func byteCount(of url: URL) throws -> Int {
        let values = try url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey])
        return values.fileSize ?? 0
    }
}

// AppModel hands an ShrinkEngine instance into `Task.detached` to keep
// compression off the main actor, which under Swift 6 strict concurrency
// requires a Sendable proof. `@unchecked` rather than automatic synthesis
// because `ShrinkEngine` is a class, but the claim is sound and checked
// here, next to the properties that have to stay true for it to hold:
//   - `helperProvider` is typed `@Sendable`, so the compiler (not just this
//     comment) rejects a future closure that captures mutable state.
//   - `svgCompressor` is a `let SVGCompressor`, whose own `JSContext` use is
//     protected by an `NSLock` (see SVGCompressor.swift).
// Both stored properties are `let`s set once in `init`, and `shrink(_:
// settings:)` never mutates `self`, so concurrent calls on the same
// instance are genuinely safe.
extension ShrinkEngine: @unchecked Sendable {}
