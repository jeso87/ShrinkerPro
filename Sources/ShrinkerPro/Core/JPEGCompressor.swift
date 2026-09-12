import Foundation

/// mozjpeg's `cjpeg`. Upstream invocation: `cjpeg -outfile OUT IN`.
///
/// cjpeg opens its `-outfile` argument with "wb" — truncating it — BEFORE
/// it has validated that the input is even decodable; libjpeg's error_exit
/// only fires later, once decoding actually fails (verified against the
/// vendored binary: a truncated 22892-byte JPEG passed as both `-outfile`
/// and input comes back at 0 bytes with exit code 1).
///
/// This compressor used to defend against that with private staging of its
/// own. It no longer needs to: `ShrinkEngine.shrink` guarantees `output` is
/// a scratch path the engine owns and discards on failure, never `input`
/// and never the user's destination — one staging layer for all formats
/// rather than one trustworthy compressor and three unaudited ones. That
/// also keeps upstream issue #54 (cjpeg cannot read and write the same
/// file) moot: cjpeg is never given the same path twice.
struct JPEGCompressor: Compressor {

    let executable: URL

    /// cjpeg's `-quality`, 0...100 — or `nil` to omit the flag entirely and
    /// let cjpeg apply its own built-in default of 75 (cjpeg.c:521).
    ///
    /// The `nil` case is load-bearing, not a missing value. Omitting the
    /// flag is genuinely not the same as passing 75: mozjpeg's
    /// `set_quality_ratings` also sets default subsampling as a side effect
    /// (vendor/src/mozjpeg/cjpeg.c:673), so an explicit `-quality 75`
    /// produces different bytes than no flag at all. `QualityLevel.standard`
    /// resolves to `nil` here for exactly that reason — it is what keeps its
    /// JPEG output byte-identical to every build shipped before quality was
    /// selectable.
    var quality: Int? = nil

    func compress(input: URL, output: URL) throws {
        // Switches precede the output and input operands, per cjpeg's usage.
        var arguments: [String] = []
        if let quality {
            arguments += ["-quality", "\(quality)"]
        }
        arguments += ["-outfile", output.path, input.path]

        let result = try ProcessRunner.run(executable, arguments)
        guard result.code == 0 else {
            throw ShrinkError.compressorFailed(tool: "cjpeg", code: result.code, message: result.stderr)
        }
    }
}
