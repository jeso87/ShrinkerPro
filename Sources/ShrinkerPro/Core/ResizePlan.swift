import Foundation
import CoreGraphics

/// The whole of what one file's pixels must become, resolved once by
/// `ShrinkEngine` from the single header read the router already pays for.
///
/// One value rather than several, so that a compressor cannot be handed a pair
/// of instructions that disagree — a plan claiming a crop while supplying no
/// rectangle, or a size that contradicts the shape. That is the same argument
/// the `ResizeDecision` it replaces made for being one value, extended to
/// cover a rectangle as well as a number.
///
/// Everything a compressor needs is *derived* from the three stored properties,
/// so there is nothing to keep in step.
struct ResizePlan: Equatable, Sendable {

    /// The **oriented** size the source declares — what a viewer sees, and
    /// what `cropRect` is measured against. Not the stored buffer:
    /// `ImageMetadata.Header.pixelSize` has already swapped the axes for the
    /// four 90° orientations.
    let sourceSize: PixelSize

    /// The shape to crop to, or `nil` to keep the source's own — which is
    /// every max-size-only file, and so is everything this app did before the
    /// crop existed.
    let aspect: AspectRatio?

    /// The size the result is written at.
    ///
    /// Never larger than `cropRect`. The never-upscale rule is enforced here,
    /// once, rather than re-derived by each compressor — see
    /// `2026-09-17-center-crop-design.md` §1.
    let outputSize: PixelSize

    /// The centered rectangle this plan takes out of `sourceSize`, in oriented
    /// coordinates.
    var cropRect: CGRect {
        CropGeometry.centeredCrop(in: sourceSize, aspect: aspect)
    }

    /// Whether that rectangle is actually smaller than the source. A file
    /// already the target shape is not cropped at all, rather than cropped to
    /// a rectangle identical to itself.
    var isCropping: Bool {
        Int(cropRect.width) != sourceSize.width || Int(cropRect.height) != sourceSize.height
    }

    /// The single factor the **whole image** shrinks by so that the crop lands
    /// at `outputSize`.
    ///
    /// A crop is a sub-rectangle, so scaling the whole image by the factor the
    /// *crop* needs leaves the crop at exactly its finished size — and that
    /// factor is orientation-independent, because rotating swaps the axes
    /// without changing the ratio between any two lengths. That is what lets
    /// `ImageIOCompressor` keep decoding a thumbnail instead of the full image
    /// when a crop is set; the argument is made in full there and in §5 of the
    /// spec.
    ///
    /// Never above 1: this never asks for an enlargement.
    var decodeScale: Double {
        let cropWidth = Double(cropRect.width)
        guard cropWidth > 0 else { return 1 }
        return min(1, Double(outputSize.width) / cropWidth)
    }
}
