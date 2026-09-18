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
    /// What this file's pixels must become — the shape to crop to and the size
    /// to land on — or `nil` to decode at full size and change nothing, which
    /// is every call made before the max size existed and every call for a
    /// file that already satisfies both settings.
    ///
    /// Applied during the decode this type already performs rather than as a
    /// pass after it, which is what keeps the README's single-lossy-hop
    /// guarantee true: resizing and cropping add no encode. On a relayed route
    /// it also means the carrier written for cjpeg, cwebp or pngquant is
    /// already the final shape and the final size, so the downstream encoder
    /// encodes only the pixels that survive rather than pixels that were about
    /// to be thrown away.
    var resize: ResizePlan? = nil

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
        guard let upright = ImageMetadata.applyingOrientation(decoded, orientation) else {
            throw ShrinkError.conversionFailed("could not apply the orientation of \(input.lastPathComponent)")
        }
        let image = try reshaped(upright, name: input.lastPathComponent)

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
        guard let resize else {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }

        // **The cover scale.** A crop is a sub-rectangle, so shrinking the
        // whole image by the factor the *crop* needs leaves the crop at
        // exactly its finished size — and that factor is
        // orientation-independent, because rotating swaps the axes without
        // changing the ratio between any two lengths. `max(width, height)` is
        // therefore the same number before and after the rotation this type
        // bakes in below, and there is no axis swap to get wrong here.
        //
        // So a crop keeps the thumbnail's memory advantage instead of paying
        // for a full decode: a 48MP photo cropped to 1200×1200 decodes
        // 1600×1200 rather than 8000×6000, and `applyingOrientation` then
        // allocates the small buffer rather than the large one.
        //
        // With no scaling to do — ratio-only cropping, or a file already
        // within the cap — the factor is 1 and the file takes the full decode
        // it always took. That is correct rather than a missed saving: the
        // output genuinely is those pixels.
        let longestSide = Double(resize.sourceSize.longestSide)
        let thumbnailMaxPixelSize = Int((longestSide * resize.decodeScale).rounded(.up))
        guard thumbnailMaxPixelSize > 0, Double(thumbnailMaxPixelSize) < longestSide else {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize,
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

    /// Center-crops and, where it still has to, scales an already-upright
    /// image to `resize.outputSize`.
    ///
    /// **Both happen after the orientation bake, and that is not negotiable.**
    /// A crop is defined on the image as a viewer sees it, so cutting the
    /// stored buffer of a portrait phone photo would take the rectangle out of
    /// the wrong axis and produce a file that is the requested shape on disk
    /// and the wrong shape on screen. That is the failure
    /// `2026-09-16-max-size-resize-design.md` §3 ruled out for the cap,
    /// applied to a rectangle instead of a number.
    ///
    /// The rectangle is recomputed from the image actually in hand rather than
    /// from the size `decode` predicted, because
    /// `kCGImageSourceThumbnailMaxPixelSize` is a bound and not an exact
    /// request — the decoded buffer can land a pixel either side of it.
    ///
    /// Worth knowing when reading this: `CGImage.cropping(to:)` measures from
    /// the top-left while `CGContext` is y-up. For a *centered* rectangle that
    /// difference is invisible, because the rectangle is identical whichever
    /// way y counts. One fewer way to be wrong.
    private func reshaped(_ image: CGImage, name: String) throws -> CGImage {
        guard let resize else { return image }

        let rect = CropGeometry.centeredCrop(
            inImageOfWidth: image.width, height: image.height, aspect: resize.aspect
        )
        let wantsCrop = Int(rect.width) != image.width || Int(rect.height) != image.height
        let target = resize.outputSize

        // Not cropping and already the right size: hand back exactly what came
        // in. This is the max-size-only path, and keeping it untouched is what
        // makes a resize byte-for-byte the operation it was before cropping
        // existed.
        guard wantsCrop || image.width != target.width || image.height != target.height else {
            return image
        }

        // `cropping(to:)` is a view onto the same pixel data — no copy, no
        // resample. It returns nil only for a rectangle outside the image,
        // which `centeredCrop` cannot produce; falling back to the whole image
        // there gives the same "compressed but not reshaped" outcome a file
        // already the right shape gets, rather than an error nobody can act on.
        let cropped = wantsCrop ? (image.cropping(to: rect) ?? image) : image

        // **A cropped image is always redrawn, even when it is already the
        // target size.** `cropping(to:)` returns an image that shares its
        // parent's backing store, describing a sub-rectangle of it rather than
        // owning its own pixels — and ImageIO will not encode that to every
        // format. Handing one straight to the TGA carrier failed outright:
        // "ImageIO failed to encode … as com.truevision.tga-image", which took
        // out JPEG, WebP and PNG at once, since all three are reached through
        // a carrier whenever the pixels are being reworked.
        //
        // The resize path never met this because a thumbnail is a fresh buffer
        // ImageIO allocated itself. So the draw below is not only the scale —
        // it is also what gives a cropped image pixels of its own.
        guard let context = ImageMetadata.makeBitmapContext(
            width: target.width, height: target.height, like: cropped
        ) else {
            throw ShrinkError.conversionFailed(
                "could not scale \(name) to \(target.width)×\(target.height)"
            )
        }
        context.interpolationQuality = .high
        context.draw(
            cropped,
            in: CGRect(x: 0, y: 0, width: target.width, height: target.height)
        )
        return context.makeImage() ?? cropped
    }
}

/// ImageIO type identifiers used by the conversion paths above. Declared
/// once here rather than as string literals scattered across call sites.
enum RasterUTType {
    static let avif = "public.avif"
    static let heic = "public.heic"
}
