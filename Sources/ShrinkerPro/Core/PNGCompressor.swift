import Foundation

/// pngquant. Upstream invocation: `pngquant -fo OUT IN`
/// (`-f` overwrite existing, `-o` output path).
///
/// pngquant writes to a private tempname and renames it over `-o` only on
/// success (vendor/src/pngquant/pngquant.c:640-676), and a truncated PNG
/// does leave the target untouched (checked against the vendored binary:
/// exit 25, file byte-identical). That is an observation about this
/// version, not a contract — so it is not what the user's original is
/// protected by. `output` here is never the user's file: `ShrinkEngine`
/// hands every compressor a scratch path it owns. See `Compressor`.
///
/// Then oxipng, when it is bundled: a lossless pass over pngquant's result
/// that reorders filters and recompresses the deflate stream, so the PNG is
/// smaller and its pixels are exactly pngquant's. It keeps every chunk
/// (`--strip` is left at none) and the interlacing, so metadata handling is
/// still pngquant's alone. The pass is an extra: when it fails, or its
/// result is not smaller, pngquant's output stands.
struct PNGCompressor: Compressor {

    let executable: URL
    /// oxipng, or `nil` to skip the lossless pass.
    var losslessPass: URL? = nil

    func compress(input: URL, output: URL) throws {
        let result = try ProcessRunner.run(executable, ["-fo", output.path, input.path])
        guard result.code == 0 else {
            throw ShrinkError.compressorFailed(tool: "pngquant", code: result.code, message: result.stderr)
        }
        if let losslessPass { Self.squeeze(output, with: losslessPass) }
    }

    /// oxipng's level 2 (its default: fast, close to the best), two threads
    /// because the engine already shrinks several files at once.
    static func squeeze(_ png: URL, with oxipng: URL) {
        let squeezed = png.deletingLastPathComponent()
            .appendingPathComponent("\(UUID().uuidString)-lossless.png")
        defer { try? FileManager.default.removeItem(at: squeezed) }
        guard let result = try? ProcessRunner.run(
            oxipng, ["-o", "2", "-i", "keep", "-t", "2", "-q", "--out", squeezed.path, png.path]
        ), result.code == 0,
            let before = try? png.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            let after = try? squeezed.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            after > 0, after < before
        else { return }
        _ = try? FileManager.default.replaceItemAt(png, withItemAt: squeezed)
    }
}
