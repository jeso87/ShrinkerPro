import Foundation

/// Compresses a single image file. Implementations are stateless with respect
/// to individual calls and safe to reuse across files.
protocol Compressor {
    /// Reads `input` and writes the compressed result to `output`.
    ///
    /// Contract, enforced by the only caller (`ShrinkEngine.shrink`):
    /// `output` is always a freshly-named scratch path owned by the engine.
    /// It is never `input`, never a file the user cares about, and is
    /// deleted if this call throws. Implementations may therefore truncate,
    /// clobber, or partially write `output` freely — several of the
    /// vendored CLI tools do exactly that before they have finished
    /// validating their input.
    ///
    /// The corollary is the part that matters: an implementation must never
    /// write to `input`, and a caller must never pass a path it cannot
    /// afford to lose as `output`. Promotion onto the user's destination is
    /// the engine's job, and it only happens after a clean exit.
    func compress(input: URL, output: URL) throws
}

enum ShrinkError: Error, LocalizedError {
    case unsupportedFormat(String)
    case helperMissing(String)
    case compressorFailed(tool: String, code: Int32, message: String)
    case javascriptFailed(String)
    case outputNotWritten(URL)
    /// An ImageIO decode or encode step failed — either a real conversion
    /// target (AVIF, or HEIC's same-format re-encode) or a lossless
    /// intermediate on the way to cjpeg/cwebp. See `ImageIOCompressor`.
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "Only SVG, PNG, GIF, JPEG, WebP, AVIF, HEIC and HEIF are supported (got \"\(ext)\")."
        case .helperMissing(let name):
            return "The bundled \(name) tool is missing. The app may be damaged — try reinstalling."
        case .compressorFailed(let tool, let code, let message):
            let detail = message.isEmpty ? "" : ": \(message)"
            return "\(tool) failed with exit code \(code)\(detail)"
        case .javascriptFailed(let message):
            return "SVG optimization failed: \(message)"
        case .outputNotWritten(let url):
            return "No output was written to \(url.lastPathComponent)."
        case .conversionFailed(let message):
            return "Image conversion failed: \(message)"
        }
    }
}
