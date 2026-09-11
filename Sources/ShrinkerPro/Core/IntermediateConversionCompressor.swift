import Foundation

/// Runs a two-stage conversion: decode `input` via ImageIO to a lossless
/// intermediate (TGA or PNG — see `IntermediateFormat`), then hand that
/// intermediate to `downstream` (cjpeg or cwebp) as its own `input`,
/// targeting the same `output` `ShrinkEngine` gave this compressor.
///
/// Used only when the destination encoder can't read the source format at
/// all: cjpeg for any non-JPEG source, and cwebp for a HEIC/AVIF source.
/// See `ConversionRouter.route`'s `.viaIntermediate` case.
///
/// The intermediate is this type's own private scratch file, entirely
/// separate from the `output` scratch `ShrinkEngine.shrink` already owns
/// and stages through — it is created fresh, in the system temporary
/// directory, and removed on every path out of `compress(input:output:)`,
/// success or throw, via `defer`. `downstream` still receives `output`
/// exactly as `ShrinkEngine` nominated it, so the no-compressor-writes-
/// straight-to-the-destination invariant is untouched: this type only adds
/// a second, equally-disposable scratch file upstream of the existing one.
struct IntermediateConversionCompressor: Compressor {

    let intermediate: IntermediateFormat
    let downstream: Compressor
    /// Handed to the ImageIO stage below, so the intermediate is authored
    /// carrying exactly the metadata the user asked to keep.
    ///
    /// This matters for one destination in particular: WebP. ImageIO cannot
    /// write WebP, so a post-pass over cwebp's output is impossible, and the
    /// intermediate's own metadata is the only thing cwebp has to copy from.
    /// For a TGA carrier it is inert — TGA holds no metadata — and the JPEG
    /// that follows gets its metadata from the post-pass instead.
    var policy: MetadataPolicy = .all

    func compress(input: URL, output: URL) throws {
        let intermediateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                ".\(UUID().uuidString).shrinker-intermediate.\(intermediate.fileExtension)"
            )
        defer { try? FileManager.default.removeItem(at: intermediateURL) }

        try ImageIOCompressor(utType: intermediate.utType, quality: nil, policy: policy)
            .compress(input: input, output: intermediateURL)

        try downstream.compress(input: intermediateURL, output: output)
    }
}
