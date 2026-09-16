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
/// **This type is where rotation is resolved**, for both jobs. ImageIO
/// decodes the *stored* pixel buffer and does not apply EXIF orientation, so
/// every path through here bakes the orientation into the pixels and writes
/// the result with no orientation tag. Doing it here rather than at each
/// call site is what makes the fix total: the intermediates go through this
/// type too, so a rotated HEIC reaches cjpeg already upright, which is the
/// one thing a TGA carrier could never have expressed.
///
/// `quality` is `nil` for a lossless intermediate (TGA/PNG ignore the
/// lossy-compression-quality option regardless, but passing nothing makes
/// that explicit rather than relying on the encoder's indifference) and
/// `QualitySettings.unitScale` — resolved from the user's `QualityLevel` —
/// for a real lossy target.
struct ImageIOCompressor: Compressor {

    let utType: String
    let quality: Double?
    /// What to carry across from the source. Applied here for outputs
    /// ImageIO itself writes (AVIF/HEIC) and for the PNG intermediate, whose
    /// metadata is the *only* way WebP output can receive any — cwebp reads
    /// it back out with `-metadata all`, and ImageIO cannot write WebP to
    /// correct it afterwards.
    var policy: MetadataPolicy = .all
    /// The longest side the decoded image may keep, or `nil` to decode at
    /// full size — which is every call made before the max size existed, and
    /// every call for a file already within it.
    ///
    /// Applied during the decode this type already performs rather than as a
    /// pass after it, which is what keeps the README's single-lossy-hop
    /// guarantee true: resizing adds no encode. On a relayed route it also
    /// means the carrier written for cjpeg, cwebp or pngquant is already the
    /// final size, so the downstream encoder does less work rather than
    /// encoding pixels that were about to be thrown away.
    var maxDimension: Int? = nil

    func compress(input: URL, output: URL) throws {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else {
            throw ShrinkError.conversionFailed("could not open \(input.lastPathComponent) for reading")
        }
        guard let decoded = decode(source) else {
            throw ShrinkError.conversionFailed("could not decode \(input.lastPathComponent) — unrecognized or corrupt image data")
        }

        // The orientation is read from the file rather than passed in, so
        // this holds for the second stage of a relay too: an intermediate
        // this type already wrote is upright and untagged, making the bake a
        // no-op there rather than a second rotation.
        let orientation = ImageMetadata.orientation(of: input)
        guard let image = ImageMetadata.applyingOrientation(decoded, orientation) else {
            throw ShrinkError.conversionFailed("could not apply the orientation of \(input.lastPathComponent)")
        }

        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, utType as CFString, 1, nil) else {
            throw ShrinkError.conversionFailed("could not create an image destination for \(utType)")
        }

        var options: [CFString: Any] = [:]
        if let quality {
            options[kCGImageDestinationLossyCompressionQuality] = quality
        }
        // Never optional — see the size measurements on
        // `ImageMetadata.rewriteMetadata`. ImageIO's padded XMP packet would
        // otherwise add kilobytes to every file this writes.
        options[kCGImageMetadataShouldExcludeXMP] = true

        // No orientation key is ever written: the pixels above already carry
        // it, and a tag repeating the instruction would turn the image a
        // second time in any viewer that honoured it.
        if let metadata = ImageMetadata.filteredMetadata(
            of: input, policy: policy, wasRotated: orientation != .up
        ) {
            CGImageDestinationAddImageAndMetadata(destination, image, metadata, options as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, image, options as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw ShrinkError.conversionFailed("ImageIO failed to encode \(output.lastPathComponent) as \(utType)")
        }
    }

    /// The stored pixel buffer, at full size or scaled down to `maxDimension`.
    ///
    /// The resizing decode is `CGImageSourceCreateThumbnailAtIndex` with
    /// `kCGImageSourceThumbnailMaxPixelSize`, whose semantics *are* the rule
    /// this feature promises: it constrains the larger dimension and
    /// preserves the aspect ratio. Expressing the rule by choosing that API,
    /// rather than by computing a target size here, is what keeps
    /// "landscape by width, portrait by height" from being an arithmetic
    /// branch that could be got backwards.
    ///
    /// `kCGImageSourceCreateThumbnailWithTransform` is deliberately **not**
    /// set. It would apply the source's orientation itself, and this type
    /// bakes orientation in one place — `ImageMetadata.applyingOrientation`,
    /// verified against ImageIO's own transform output for all eight cases —
    /// so letting the thumbnail API do it too would turn rotated images
    /// twice. The cap is unaffected by which of the two runs first: rotating
    /// swaps the axes without changing the longest side.
    ///
    /// `kCGImageSourceCreateThumbnailFromImageAlways` is set because an
    /// embedded thumbnail is not the image — it is a small, often stale
    /// preview, and `ThumbnailFromImageIfAbsent` would silently hand one
    /// back in place of the photo the user dropped.
    private func decode(_ source: CGImageSource) -> CGImage? {
        guard let maxDimension else {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            // A source ImageIO can open but cannot produce a thumbnail from
            // is not a reason to fail the whole shrink: fall back to the
            // full-size decode. The file then comes out compressed but
            // un-resized, which is the same outcome as a file already within
            // the cap, rather than an error for something the user can't act
            // on.
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// ImageIO type identifiers used by the conversion paths above. Declared
/// once here rather than as string literals scattered across call sites.
enum RasterUTType {
    static let avif = "public.avif"
    static let heic = "public.heic"
}
