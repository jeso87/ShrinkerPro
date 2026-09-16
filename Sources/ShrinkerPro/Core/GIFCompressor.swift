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
    /// The longest side this GIF may keep, or `nil` for no resizing.
    ///
    /// GIF is the one format resized by something other than ImageIO, and
    /// that is the whole reason gifsicle keeps the job: an ImageIO round trip
    /// writes a single frame, so an animation would arrive at the user as a
    /// still. `--resize-fit` is also the exact rule the rest of the app
    /// applies — shrink to fit the box, preserve the aspect ratio, do nothing
    /// to an image already inside it — so the semantics are gifsicle's own
    /// rather than a second implementation of them here.
    var maxDimension: Int? = nil

    func compress(input: URL, output: URL) throws {
        var arguments = ["-o", output.path, input.path, "-O=2", "-i"]
        if let maxDimension {
            // `--resize-fit WxH` with the same number on both axes is a box,
            // which is what capping the longest side means: a landscape GIF
            // hits the width, a portrait one the height.
            //
            // `--resize-method mix` because gifsicle's default sampling
            // ("point") drops pixels outright, which on the flat colour and
            // hard edges GIFs are usually made of is visibly worse than
            // averaging them.
            arguments += ["--resize-fit", "\(maxDimension)x\(maxDimension)", "--resize-method", "mix"]
        }
        let result = try ProcessRunner.run(executable, arguments)
        guard result.code == 0 else {
            throw ShrinkError.compressorFailed(tool: "gifsicle", code: result.code, message: result.stderr)
        }
    }
}
