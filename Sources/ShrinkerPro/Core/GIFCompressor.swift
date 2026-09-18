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
    ///
    /// Cropping is gifsicle's too, with one precaution the flag's
    /// documentation does not mention — see `--unoptimize` below, and
    /// `2026-09-17-center-crop-design.md` §6.
    var resize: ResizePlan? = nil

    func compress(input: URL, output: URL) throws {
        var arguments = ["-o", output.path]

        if let resize, resize.isCropping {
            let rect = resize.cropRect
            // **`--unoptimize` first, and it is what makes cropping a GIF
            // correct at all.** gifsicle's `analyze_crop` measures the crop
            // against the bounding box of the *input frames*, not the logical
            // screen. On an optimised GIF whose frames do not reach the edges
            // of the screen, a rectangle computed from the screen size is
            // either silently clipped or rejected outright. Measured on a
            // 300×300 GIF with 120×120 frames at (10,10): asking for
            // `0,65+300x169` wrote a 130×65 file and exited 0, and
            // `250,250+300x300` failed with "cropping dimensions don't fit
            // image". Unoptimising expands every frame to the full screen, so
            // the bounding box and the screen become the same rectangle and
            // both cases come out exactly right.
            //
            // It costs nothing: `-O=2` below re-optimises, and on the 120×120
            // fixture cropping with and without `--unoptimize` produced
            // byte-identical 590 byte output with all 12 frames intact.
            //
            // A resize alone has never needed it, because scaling the logical
            // screen does not index into it — so this is passed only when
            // there is a crop.
            arguments += ["--unoptimize"]
            // Before the input path, and that placement is load-bearing:
            // `--crop` is an *image* option, which gifsicle applies to "the
            // following input frames". Appended after the input it is accepted
            // and silently does nothing.
            arguments += [
                "--crop",
                "\(Int(rect.minX)),\(Int(rect.minY))+\(Int(rect.width))x\(Int(rect.height))",
            ]
        }

        arguments += [input.path, "-O=2", "-i"]

        if let resize {
            // Two different flags, because they make two different promises.
            //
            // Without a crop, `--resize-fit` only ever shrinks, which is this
            // app's never-upscale rule stated by the tool rather than
            // reimplemented beside it. That is the shipped max-size path and
            // it is left exactly as it was.
            //
            // With a crop, the promise is an exact size, and `--resize-fit`
            // cannot keep it: it preserves the aspect ratio of what it is
            // given, and the cropped GIF's ratio can differ from the target's
            // by the pixel that rounding moved. Asking for 280×40 that way
            // produced 279×40. `--resize` takes the numbers literally.
            //
            // It cannot enlarge anything here, and that is a property of the
            // planner rather than of the flag: `outputSize` is only ever
            // shrunk from the crop rectangle, so it is never larger than what
            // `--crop` above leaves behind.
            //
            // `--resize-method mix` either way, because gifsicle's default
            // sampling ("point") drops pixels outright, which on the flat
            // colour and hard edges GIFs are usually made of is visibly worse
            // than averaging them.
            let size = "\(resize.outputSize.width)x\(resize.outputSize.height)"
            arguments += [resize.isCropping ? "--resize" : "--resize-fit", size]
            arguments += ["--resize-method", "mix"]
        }
        let result = try ProcessRunner.run(executable, arguments)
        guard result.code == 0 else {
            throw ShrinkError.compressorFailed(tool: "gifsicle", code: result.code, message: result.stderr)
        }
    }
}
