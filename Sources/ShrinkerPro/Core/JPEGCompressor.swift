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

    func compress(input: URL, output: URL) throws {
        let result = try ProcessRunner.run(executable, ["-outfile", output.path, input.path])
        guard result.code == 0 else {
            throw ShrinkError.compressorFailed(tool: "cjpeg", code: result.code, message: result.stderr)
        }
    }
}
