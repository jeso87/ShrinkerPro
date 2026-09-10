import Foundation

/// Fixed encoder quality for every lossy conversion path added by format
/// conversion: cwebp, and ImageIO's AVIF/HEIC encoder. The spec keeps a
/// quality slider explicitly out of scope for this pass ("Out of scope: A
/// quality slider") but still requires *a* value, stated in code, used
/// consistently.
///
/// 80 was chosen because it's the value the spec's own measured baseline
/// used for WebP ("WebP (cwebp -q 80) 18,828 bytes" against the project's
/// 244,413-byte PNG fixture) — using the same number here means this
/// implementation's output sizes are directly comparable to that baseline
/// rather than a coincidentally-close-but-different result. It sits in
/// the normal "visually lossless for photographic content" range quoted
/// for both AV1-family (AVIF) and WebP encoders, with room below it for a
/// future quality setting to trade size for fidelity.
///
/// This does not touch cjpeg: the existing same-format JPEG path
/// (`JPEGCompressor`) already ships at cjpeg's own default (quality 75,
/// unspecified on its command line) and that is out of scope to change
/// here — a non-JPEG source converting to JPEG reuses that exact same
/// `JPEGCompressor`, at its existing quality, via an intermediate.
enum ConversionQuality {
    /// 0...1 scale, as ImageIO's `kCGImageDestinationLossyCompressionQuality` expects.
    static let unitScale: Double = 0.80

    /// 0...100 scale, as cwebp's `-q` flag expects.
    static let cwebpScale: Int = 80
}
