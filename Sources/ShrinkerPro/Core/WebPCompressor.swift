import Foundation

/// cwebp (libwebp 1.6.0, vendored static arm64 — see
/// scripts/build-compressors.sh). Reads PNG, JPEG, or WebP directly;
/// it cannot read HEIC or AVIF at all, so those go through
/// `IntermediateConversionCompressor` first (see `ConversionRouter`).
///
/// Invocation: `cwebp -q <ConversionQuality.cwebpScale> -o OUT IN`. Checked
/// against the vendored binary: on a file it can't decode at all (bad PNG
/// signature), cwebp exits 1 having left its `-o` target completely
/// untouched. That's an observation about this version, not a contract
/// this type relies on — same reasoning as `PNGCompressor`'s doc comment.
/// `output` here is never the user's file regardless: `ShrinkEngine.shrink`
/// hands every compressor a scratch path it owns and only promotes it
/// after a clean, non-empty run. See the contract on `Compressor`.
struct WebPCompressor: Compressor {

    let executable: URL

    func compress(input: URL, output: URL) throws {
        let result = try ProcessRunner.run(
            executable, ["-q", "\(ConversionQuality.cwebpScale)", "-o", output.path, input.path]
        )
        guard result.code == 0 else {
            throw ShrinkError.compressorFailed(tool: "cwebp", code: result.code, message: result.stderr)
        }
    }
}
