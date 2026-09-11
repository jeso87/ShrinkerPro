import Foundation

/// cwebp (libwebp 1.6.0, vendored static arm64 — see
/// scripts/build-compressors.sh). Reads PNG, JPEG, or WebP directly;
/// it cannot read HEIC or AVIF at all, so those go through
/// `IntermediateConversionCompressor` first (see `ConversionRouter`).
///
/// Invocation: `cwebp -q <ConversionQuality.cwebpScale> -metadata <policy>
/// -o OUT IN`. Checked against the vendored binary: on a file it can't
/// decode at all (bad PNG signature), cwebp exits 1 having left its `-o`
/// target completely untouched. That's an observation about this version,
/// not a contract this type relies on — same reasoning as `PNGCompressor`'s
/// doc comment. `output` here is never the user's file regardless:
/// `ShrinkEngine.shrink` hands every compressor a scratch path it owns and
/// only promotes it after a clean, non-empty run. See the contract on
/// `Compressor`.
///
/// **WebP is the one output format with no metadata post-pass available.**
/// ImageIO cannot write WebP (`org.webmproject.webp` is absent from
/// `CGImageDestinationCopyTypeIdentifiers()`, verified), so whatever cwebp
/// emits is final and this flag is the only lever. libwebp's default is
/// `none`, which is why every WebP output used to lose orientation and
/// everything else regardless of source.
struct WebPCompressor: Compressor {

    let executable: URL
    var policy: MetadataPolicy = .all

    /// cwebp's `-metadata` takes a comma-separated list, of which `all` and
    /// `none` are the two useful settings here. There is deliberately no
    /// case mapping `.copyright` to a partial list: the flag has no way to
    /// name individual tags, so `ConversionRouter` never routes a
    /// `.copyright` job through cwebp reading the user's original — it
    /// authors a PNG intermediate carrying exactly the tags to keep, and
    /// this then copies *all* of that. See `ConversionRouter.cwebpNeedsNoHelp`.
    private var metadataArgument: String {
        switch policy {
        case .all, .copyright: return "all"
        case .stripped: return "none"
        }
    }

    func compress(input: URL, output: URL) throws {
        let result = try ProcessRunner.run(
            executable,
            ["-q", "\(ConversionQuality.cwebpScale)",
             "-metadata", metadataArgument,
             "-o", output.path, input.path]
        )
        guard result.code == 0 else {
            throw ShrinkError.compressorFailed(tool: "cwebp", code: result.code, message: result.stderr)
        }
    }
}
