import Foundation
import ImageIO
import CoreGraphics

/// Decodes any ImageIO-readable input (PNG, JPEG, WebP, AVIF, HEIC/HEIF —
/// everything `ShrinkEngine.supportedExtensions` lists except SVG and GIF,
/// which never reach this type) and encodes it to `utType`.
///
/// Used for two distinct jobs, both plain ImageIO round trips with no
/// vendored binary involved:
///   - a real conversion target macOS can write natively (AVIF, and HEIC
///     for the "keep original" case on a HEIC/HEIF input — see
///     `ConversionRoute.sameFormat`);
///   - a lossless intermediate (TGA/PNG) that hands pixels to a CLI
///     encoder that can't read the original source format at all. See
///     `IntermediateConversionCompressor`.
///
/// `quality` is `nil` for a lossless intermediate (TGA/PNG ignore the
/// lossy-compression-quality option regardless, but passing nothing makes
/// that explicit rather than relying on the encoder's indifference) and
/// `ConversionQuality.unitScale` for a real lossy target.
struct ImageIOCompressor: Compressor {

    let utType: String
    let quality: Double?

    func compress(input: URL, output: URL) throws {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else {
            throw ShrinkError.conversionFailed("could not open \(input.lastPathComponent) for reading")
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ShrinkError.conversionFailed("could not decode \(input.lastPathComponent) — unrecognized or corrupt image data")
        }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, utType as CFString, 1, nil) else {
            throw ShrinkError.conversionFailed("could not create an image destination for \(utType)")
        }

        var options: [CFString: Any] = [:]
        if let quality {
            options[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw ShrinkError.conversionFailed("ImageIO failed to encode \(output.lastPathComponent) as \(utType)")
        }
    }
}

/// ImageIO type identifiers used by the conversion paths above. Declared
/// once here rather than as string literals scattered across call sites.
enum RasterUTType {
    static let avif = "public.avif"
    static let heic = "public.heic"
}
