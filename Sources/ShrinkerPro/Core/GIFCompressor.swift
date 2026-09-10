import Foundation

/// gifsicle. Upstream invocation: `gifsicle -o OUT IN -O=2 -i`
/// (`-O=2` optimization level 2, `-i` interlace).
///
/// gifsicle truncates its `-o` target even when the input turns out to be
/// unreadable: `output_frames()` is gated on `error_count == 0`
/// (vendor/src/gifsicle/src/gifsicle.c:2225), but read errors are rolled
/// back before that gate is reached — `if (!no_ignore_errors) error_count =
/// old_error_count;` at gifsicle.c:746 — so the gate sees zero, the target
/// is written, and the buffered error is only re-raised afterwards as exit
/// status 1. Reproduced against the shipped binary with this exact argv: a
/// truncated 61156-byte GIF at the `-o` path came back as 835 bytes.
///
/// That is why `output` here is never the user's file: `ShrinkEngine.shrink`
/// hands every compressor a scratch path it owns and promotes it only after
/// a clean exit. See the contract on `Compressor`.
struct GIFCompressor: Compressor {

    let executable: URL

    func compress(input: URL, output: URL) throws {
        let result = try ProcessRunner.run(
            executable, ["-o", output.path, input.path, "-O=2", "-i"]
        )
        guard result.code == 0 else {
            throw ShrinkError.compressorFailed(tool: "gifsicle", code: result.code, message: result.stderr)
        }
    }
}
