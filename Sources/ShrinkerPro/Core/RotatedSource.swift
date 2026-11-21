import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Rotate Left and Rotate Right on a result: the original, turned, written as a lossless TIFF
/// the engine then shrinks into the result's own file. Going back to the original each time
/// means a photo turned four times is still one generation from it, never four.
enum RotatedSource {
    /// The format to write a result back in, read from its file's extension, or nil when Rotate
    /// can't rewrite it: an animated GIF or an SVG is left alone.
    static func sessionFormat(forOutputExtension ext: String) -> SessionFormat? {
        switch ext.lowercased() {
        case "jpg", "jpeg": return .jpeg
        case "png": return .png
        case "webp": return .webp
        case "avif": return .avif
        case "jxl": return .jxl
        case "heic", "heif": return .heic
        case "tif", "tiff": return .tiff
        default: return nil
        }
    }

    /// Writes `original`, upright and then turned, into `directory` as `<name>.tiff` (LZW, so
    /// nothing is lost), with the original's metadata and no orientation of its own.
    static func write(_ original: URL, turn: PhotoTurn, into directory: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(original as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ShrinkError.conversionFailed("could not read \(original.lastPathComponent) to rotate it")
        }
        guard let upright = ImageMetadata.applyingOrientation(image, ImageMetadata.orientation(of: original)),
              let turned = turn.apply(to: upright) else {
            throw ShrinkError.conversionFailed("could not rotate \(original.lastPathComponent)")
        }
        let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil).flatMap { CGImageMetadataCreateMutableCopy($0) }
            ?? CGImageMetadataCreateMutable()
        // The pixels are upright now, and their old size no longer describes them.
        CGImageMetadataSetValueMatchingImageProperty(
            metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, 1 as CFNumber
        )
        for path in ["exif:PixelXDimension", "exif:PixelYDimension"] {
            CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString)
        }
        let output = directory.appendingPathComponent(original.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("tiff")
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.tiff.identifier as CFString, 1, nil)
        else { throw ShrinkError.conversionFailed("could not write the rotated \(original.lastPathComponent)") }
        let options: [CFString: Any] = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]]
        CGImageDestinationAddImageAndMetadata(destination, turned, metadata, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ShrinkError.conversionFailed("could not write the rotated \(original.lastPathComponent)")
        }
        return output
    }
}
