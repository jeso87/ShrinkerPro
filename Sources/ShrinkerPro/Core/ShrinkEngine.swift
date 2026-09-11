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

    /// Compresses `input` according to `settings` and reports the size delta.
    ///
    /// Note: `OutputPathResolver.resolve` creates the destination directory
    /// as a side effect of computing the path (a faithful port of
    /// upstream's `makeDir.sync` placement) — it runs before compression is
    /// attempted below. So if compression subsequently throws, an empty
    /// destination directory (e.g. `minified/`) can be left behind on disk.
    /// That is upstream's existing behavior, not a bug introduced here, and
    /// is out of scope to "fix" by adding cleanup.
    func shrink(_ input: URL, settings: OutputSettings) throws -> ShrinkResult {
        let ext = input.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else {
            throw ShrinkError.unsupportedFormat(ext)
        }

        let originalBytes = try byteCount(of: input)
        let plan = try plan(for: ext, input: input, settings: settings)
        let output = try OutputPathResolver.resolve(
            input: input, settings: settings, targetExtension: plan.targetExtension
        )

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
                policy: settings.metadataPolicy,
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

    /// Everything `shrink` needs to know about how one file will be
    /// handled, decided before a single byte is written.
    private struct Plan {
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
    private func plan(for ext: String, input: URL, settings: OutputSettings) throws -> Plan {
        switch ext {
        case "svg":
            return Plan(compressor: svgCompressor, targetExtension: nil,
                        needsMetadataPostPass: false, wasRotated: false)
        case "gif":
            return Plan(compressor: GIFCompressor(executable: try helperProvider("gifsicle")),
                        targetExtension: nil, needsMetadataPostPass: false, wasRotated: false)
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
        let orientation = ImageMetadata.orientation(of: input)
        let context = RoutingContext(
            isUpright: orientation == .up,
            policy: settings.metadataPolicy
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

        return Plan(
            compressor: try compressor(for: route, policy: settings.metadataPolicy),
            targetExtension: outputExtension(for: route),
            needsMetadataPostPass: route.needsMetadataPostPass,
            wasRotated: orientation != .up
        )
    }

    /// Turns a routing decision into an actual `Compressor`, supplying the
    /// helper binaries and fixed quality `ConversionRouter` has no
    /// business knowing about. `.direct(target:)` and
    /// `.viaIntermediate(target:)` carry `DirectTarget`/`RelayedTarget`
    /// rather than the general `ConversionFormat` (see `ConversionRouter
    /// .swift`), so the switches below are already exhaustive over exactly
    /// the combinations the router can produce — there is no `.jpeg` case
    /// to handle under `.direct`, and no `.avif` case under
    /// `.viaIntermediate`, because those types don't have them. Nothing
    /// left here for a `preconditionFailure` to stand in for.
    private func compressor(for route: ConversionRoute, policy: MetadataPolicy) throws -> Compressor {
        switch route {
        case .sameFormat(let native):
            switch native {
            case .png:
                return PNGCompressor(executable: try helperProvider("pngquant"))
            case .jpeg:
                return JPEGCompressor(executable: try helperProvider("cjpeg"))
            case .webp:
                return WebPCompressor(executable: try helperProvider("cwebp"), policy: policy)
            case .avif:
                return ImageIOCompressor(utType: RasterUTType.avif, quality: ConversionQuality.unitScale, policy: policy)
            case .heic:
                return ImageIOCompressor(utType: RasterUTType.heic, quality: ConversionQuality.unitScale, policy: policy)
            }

        case .direct(let target):
            switch target {
            case .avif:
                return ImageIOCompressor(utType: RasterUTType.avif, quality: ConversionQuality.unitScale, policy: policy)
            case .webp:
                return WebPCompressor(executable: try helperProvider("cwebp"), policy: policy)
            }

        case .viaIntermediate(let target, let intermediate):
            switch target {
            case .jpeg:
                return IntermediateConversionCompressor(
                    intermediate: intermediate,
                    downstream: JPEGCompressor(executable: try helperProvider("cjpeg")),
                    policy: policy
                )
            case .webp:
                return IntermediateConversionCompressor(
                    intermediate: intermediate,
                    downstream: WebPCompressor(executable: try helperProvider("cwebp"), policy: policy),
                    policy: policy
                )
            case .png:
                return IntermediateConversionCompressor(
                    intermediate: intermediate,
                    downstream: PNGCompressor(executable: try helperProvider("pngquant")),
                    policy: policy
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

    private func byteCount(of url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
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
