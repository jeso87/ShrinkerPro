import Foundation

/// Compresses a single image file. Implementations are stateless with respect
/// to individual calls and safe to reuse across files.
///
/// That second sentence is the whole of the `Sendable` claim: a `ShrinkPlan`
/// carries its chosen compressor from wherever the plan was made to wherever
/// it is executed, which under Swift 6 requires the proof. Every conformer is
/// a struct of immutable value fields bar `SVGCompressor`, whose `JSContext`
/// is serialized behind an `NSLock` — see its own conformance.
protocol Compressor: Sendable {
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

/// An error that carries a separate, translated message for the app's alert.
///
/// `Core` compiles into both the app and the `shrinker` CLI, so
/// `LocalizedError.errorDescription` cannot be translated: `main.swift`
/// prints it to stderr and scripts parse that. This protocol is the app's
/// half of that split — `AppModel` prefers `localizedMessage`, the CLI never
/// reads it.
///
/// The duplication is deliberate. Relying instead on `String(localized:)`
/// falling back to its key because the CLI's `Bundle.main` has no catalog
/// would produce English today, but only by accident of bundle layout.
/// See `docs/design/specs/2026-09-20-localization-design.md`.
protocol AppDisplayableError {
    var localizedMessage: String { get }
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

extension ShrinkError: AppDisplayableError {
    var localizedMessage: String {
        switch self {
        case .unsupportedFormat(let ext):
            return String(localized: "Only SVG, PNG, GIF, JPEG, WebP, AVIF, HEIC and HEIF are supported (got \"\(ext)\").",
                          comment: "Alert body when a dropped file is a format the app cannot read.")
        case .helperMissing(let name):
            return String(localized: "The bundled \(name) tool is missing. The app may be damaged — try reinstalling.",
                          comment: "Alert body when a bundled compressor binary is absent. The placeholder is a tool name such as cjpeg.")
        case .compressorFailed(let tool, let code, let message):
            let detail = message.isEmpty ? "" : ": \(message)"
            return String(localized: "\(tool) failed with exit code \(code)\(detail)",
                          comment: "Alert body when a compressor exits non-zero. Placeholders: tool name, exit code, optional detail.")
        case .javascriptFailed(let message):
            return String(localized: "SVG optimization failed: \(message)",
                          comment: "Alert body when svgo fails.")
        case .outputNotWritten(let url):
            return String(localized: "No output was written to \(url.lastPathComponent).",
                          comment: "Alert body when a compressor reported success but produced no file.")
        case .conversionFailed(let message):
            return String(localized: "Image conversion failed: \(message)",
                          comment: "Alert body when an ImageIO decode or encode step fails.")
        }
    }
}
