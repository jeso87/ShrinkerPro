import Foundation
import ImageIO
import CoreGraphics

/// Reading orientation, baking it into pixels, and filtering everything else
/// down to the user's `MetadataPolicy`.
///
/// The app has exactly one decoder — ImageIO — and four encoders, three of
/// which are vendored CLI binaries that each treat metadata differently
/// (cjpeg copies every APPn marker but only from a JPEG input, pngquant
/// keeps PNG chunks, cwebp copies nothing unless told). Rather than
/// negotiate with each of them, orientation is resolved *here*, once, by
/// rewriting the pixels, and the policy is applied either as the properties
/// handed to ImageIO or as a post-pass over an encoder's output.
enum ImageMetadata {

    // MARK: - Orientation

    /// What one header read yields: the two facts about a file that decide
    /// its route before any pixel is decoded.
    ///
    /// They travel together because they come out of the same properties
    /// dictionary, and because reading them separately would mean opening the
    /// same `CGImageSource` twice for every file in a drop.
    struct Header: Equatable {
        var orientation: CGImagePropertyOrientation = .up
        /// The size **as a viewer sees it** — width and height swapped for
        /// the four 90° orientations, so a portrait phone photo reports its
        /// portrait size rather than the landscape buffer it is stored as.
        ///
        /// `nil` when the file declares no dimensions at all, which for a
        /// readable image means something is wrong with it. Callers treat
        /// that as "no resize" rather than guessing.
        var pixelSize: CGSize?

        /// The dimension a max size is measured against — see
        /// `2026-09-16-max-size-resize-design.md` §1. "Longest side" is the
        /// whole rule: it caps a landscape image by its width and a portrait
        /// one by its height without branching on which it is.
        var longestSide: Double? {
            pixelSize.map { Double(max($0.width, $0.height)) }
        }
    }

    /// The source's declared orientation and oriented size, or `.up` with no
    /// size if it declares neither.
    ///
    /// Cheap enough to call for every file: `CGImageSourceCopyPropertiesAtIndex`
    /// reads the container's header, it does not decode pixels. That is what
    /// lets `ShrinkEngine` consult it *before* choosing a route.
    static func header(of url: URL) -> Header {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return Header() }

        var header = Header()
        if let raw = properties[kCGImagePropertyOrientation] as? UInt32,
           let orientation = CGImagePropertyOrientation(rawValue: raw) {
            header.orientation = orientation
        }
        // `as? Double`, not `as? CGFloat`: these arrive as `CFNumber`, which
        // bridges to `NSNumber` and casts reliably to `Double`.
        if let width = properties[kCGImagePropertyPixelWidth] as? Double,
           let height = properties[kCGImagePropertyPixelHeight] as? Double {
            // The stored buffer, turned the way the file says to turn it. The
            // four 90° cases swap the axes; the flips and `.up` do not.
            switch header.orientation {
            case .left, .right, .leftMirrored, .rightMirrored:
                header.pixelSize = CGSize(width: height, height: width)
            case .up, .down, .upMirrored, .downMirrored:
                header.pixelSize = CGSize(width: width, height: height)
            }
        }
        return header
    }

    /// The source's declared orientation, or `.up` if it declares none.
    ///
    /// Kept as its own entry point for the callers that want nothing else —
    /// `ImageIOCompressor` re-reads it from the intermediate it is handed,
    /// where the size is already whatever the previous stage made it.
    static func orientation(of url: URL) -> CGImagePropertyOrientation {
        header(of: url).orientation
    }

    /// A drawing context of `width` × `height` that `image` can be drawn into.
    ///
    /// A fixed 8-bit RGBA layout rather than the source image's own
    /// bitmapInfo/colorSpace: `CGContext` rejects a good number of the layouts
    /// a real file decodes to (16-bit HEIC, indexed PNG, grayscale with
    /// alpha), and a nil context means silently skipping whatever the draw was
    /// for — which, when this lived inside `applyingOrientation`, was the
    /// rotation bug it had been written to fix. The colour space is preserved
    /// where the source has one, so this normalises layout, not colour.
    ///
    /// Shared by the rotation above and by the scale in `ImageIOCompressor`.
    /// Extracted rather than duplicated because the fallback ladder is the
    /// part that took measuring, and a second copy would be a second place to
    /// get it wrong. The eight-orientation equivalence test is what says the
    /// extraction changed nothing.
    static func makeBitmapContext(width: Int, height: Int, like image: CGImage) -> CGContext? {
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        return CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) ?? CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo
        )
    }

    /// Redraws `image` so its *pixels* carry `orientation`, returning an
    /// upright image with width and height swapped for the four 90° cases.
    /// Returns `image` untouched for `.up`, which is the overwhelmingly
    /// common case and costs nothing.
    ///
    /// The eight transforms below were verified against ImageIO's own
    /// `kCGImageSourceCreateThumbnailWithTransform` output for all eight
    /// orientations — matching dimensions and a four-quadrant colour
    /// signature in every case. That equivalence is the correctness
    /// argument, and `ImageMetadataTests` re-runs it. If this function is
    /// ever edited, check it against that test rather than re-deriving the
    /// matrices by hand: the failure mode is an image that is rotated the
    /// wrong way, which looks plausible in isolation and is only obviously
    /// wrong next to the truth.
    static func applyingOrientation(
        _ image: CGImage, _ orientation: CGImagePropertyOrientation
    ) -> CGImage? {
        guard orientation != .up else { return image }

        let width = image.width
        let height = image.height
        let quarterTurned: Bool
        switch orientation {
        case .left, .right, .leftMirrored, .rightMirrored: quarterTurned = true
        default: quarterTurned = false
        }
        let outputWidth = quarterTurned ? height : width
        let outputHeight = quarterTurned ? width : height

        guard let context = makeBitmapContext(
            width: outputWidth, height: outputHeight, like: image
        ) else { return nil }

        let w = CGFloat(width)
        let h = CGFloat(height)
        let outW = CGFloat(outputWidth)
        let outH = CGFloat(outputHeight)

        // CGContext's user space is y-up, so a visually *clockwise* turn is
        // a negative rotation here.
        var transform = CGAffineTransform.identity
        switch orientation {
        case .up:
            break
        case .upMirrored:
            transform = CGAffineTransform(translationX: outW, y: 0).scaledBy(x: -1, y: 1)
        case .down:
            transform = CGAffineTransform(translationX: outW, y: outH).rotated(by: .pi)
        case .downMirrored:
            transform = CGAffineTransform(translationX: 0, y: outH).scaledBy(x: 1, y: -1)
        case .left:
            transform = CGAffineTransform(translationX: outW, y: 0).rotated(by: .pi / 2)
        case .leftMirrored:
            transform = CGAffineTransform(translationX: outW, y: 0).rotated(by: .pi / 2)
                .translatedBy(x: w, y: 0).scaledBy(x: -1, y: 1)
        case .right:
            transform = CGAffineTransform(translationX: 0, y: outH).rotated(by: -.pi / 2)
        case .rightMirrored:
            transform = CGAffineTransform(translationX: 0, y: outH).rotated(by: -.pi / 2)
                .translatedBy(x: w, y: 0).scaledBy(x: -1, y: 1)
        @unknown default:
            break
        }

        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }

    // MARK: - Policy

    /// XMP-style tag roots kept under `MetadataPolicy.copyright`.
    ///
    /// These are the *canonical* paths ImageIO normalises to, not the
    /// classic EXIF/TIFF names: a JPEG's TIFF `Copyright` field is read back
    /// as `dc:rights` and `Artist` as `dc:creator` (verified against a file
    /// carrying both). Matching on `tiff:Copyright` here would silently keep
    /// nothing at all.
    ///
    /// Matched against the portion of a tag path before any `[`, so the
    /// language alternative `dc:rights[x-default]` and the ordered array
    /// element `dc:creator[0]` are both kept with their parent.
    static let copyrightTagRoots: Set<String> = [
        "dc:rights",
        "dc:creator",
        "photoshop:Credit",
        "photoshop:Source",
        "xmpRights:Marked",
        "xmpRights:UsageTerms",
        "xmpRights:WebStatement",
    ]

    /// Tag paths removed under every policy, because the pixels they
    /// describe have been rewritten by the time this runs.
    private static let orientationTagPaths = ["tiff:Orientation", "exif:Orientation"]

    /// The source's metadata reduced to `policy`, with orientation removed.
    /// `nil` when the result would carry nothing — which is not the same as
    /// an empty metadata object, and the callers treat it differently.
    static func filteredMetadata(
        of url: URL, policy: MetadataPolicy, wasRotated: Bool
    ) -> CGImageMetadata? {
        guard policy != .stripped,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let original = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let metadata = CGImageMetadataCreateMutableCopy(original)
        else { return nil }

        var paths: [String] = []
        CGImageMetadataEnumerateTagsUsingBlock(
            metadata, nil, [kCGImageMetadataEnumerateRecursively: true] as CFDictionary
        ) { path, _ in
            paths.append(path as String)
            return true
        }

        for path in paths {
            let root = String(path.prefix(while: { $0 != "[" }))
            let keep: Bool
            switch policy {
            case .all:
                keep = true
            case .copyright:
                keep = copyrightTagRoots.contains(root)
            case .stripped:
                keep = false
            }
            if !keep {
                CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString)
            }
        }

        for path in orientationTagPaths {
            CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString)
        }

        // Only stale once the pixels have actually been turned: these
        // describe the *stored* frame, and a 90° bake swaps them. Left alone
        // otherwise so "Keep all" really does keep all.
        if wasRotated {
            for path in ["exif:PixelXDimension", "exif:PixelYDimension"] {
                CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString)
            }
        }

        return metadata
    }

    // MARK: - Post-pass

    /// Rewrites `file`'s metadata to `policy`, taking the values from
    /// `original`, **without re-encoding the pixels**.
    ///
    /// This is how the vendored CLI encoders' output gets its metadata:
    /// cjpeg fed a TGA intermediate emits none at all, and pngquant's output
    /// has only what pngquant chose to keep. `CGImageDestinationCopyImageSource`
    /// copies the already-compressed image data across verbatim and swaps the
    /// metadata — verified byte-identical on pngquant's palette PNG
    /// (67,609 → 67,609) and 234 bytes *smaller* on mozjpeg's progressive
    /// JPEG, with identical decoded pixels in both cases. A plain
    /// decode-and-re-encode here would throw away exactly the work those
    /// encoders were run to do.
    ///
    /// Not usable for WebP: ImageIO cannot write it at all (`org.webmproject.webp`
    /// is absent from `CGImageDestinationCopyTypeIdentifiers()`, re-verified).
    /// WebP gets its metadata from the intermediate instead — see
    /// `ConversionRouter`.
    static func rewriteMetadata(
        of file: URL,
        takingFrom original: URL,
        policy: MetadataPolicy,
        utType: String,
        wasRotated: Bool,
        workingIn directory: URL
    ) throws {
        let rewritten = directory
            .appendingPathComponent("\(UUID().uuidString).\(file.pathExtension)")
        defer { try? FileManager.default.removeItem(at: rewritten) }

        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let destination = CGImageDestinationCreateWithURL(
                  rewritten as CFURL, utType as CFString, 1, nil
              )
        else { throw ShrinkError.conversionFailed("could not reopen \(file.lastPathComponent) to write its metadata") }

        // kCGImageMetadataShouldExcludeXMP is not an optimisation, it is
        // required. Without it ImageIO appends a generously padded XMP
        // packet: on a 1,421-byte JPEG, even a policy of "strip everything"
        // came back at 3,682 bytes. With it, the same case is 1,343 bytes —
        // smaller than the input, which is the only acceptable direction for
        // a compressor.
        var options: [CFString: Any] = [
            kCGImageMetadataShouldExcludeXMP: true,
            kCGImageDestinationMergeMetadata: false,
        ]
        options[kCGImageDestinationMetadata] =
            filteredMetadata(of: original, policy: policy, wasRotated: wasRotated)
            ?? CGImageMetadataCreateMutable()

        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(
            destination, source, options as CFDictionary, &error
        ) else {
            let detail = error?.takeRetainedValue().localizedDescription ?? "unknown error"
            throw ShrinkError.conversionFailed("could not write metadata to \(file.lastPathComponent): \(detail)")
        }

        // A plain remove-and-move rather than `replaceItemAt`, which
        // returns the URL the item *actually* landed at and is documented to
        // be free to choose a different one — the caller would then still be
        // holding a path with nothing at it. That risk is worth taking for
        // the user's real destination, where atomicity matters more; here
        // both paths are scratch files this process created inside one
        // temporary directory it owns, so the simple form is both safe and
        // exact. Nothing the user has is at stake if this throws: the
        // original has not been touched, and promotion has not happened yet.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: rewritten, to: file)
    }

    /// ImageIO type identifier for a final output extension, for the
    /// post-pass above. `nil` for anything ImageIO cannot write, which is
    /// how WebP (and SVG/GIF) opt out.
    static func utType(forOutputExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "public.jpeg"
        case "png": return "public.png"
        default: return nil
        }
    }
}
