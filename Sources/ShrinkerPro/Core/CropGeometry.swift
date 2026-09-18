import Foundation
import CoreGraphics

/// Which rectangle a center crop takes out of an image.
///
/// Its own type, pure and IO-free, because this is the whole of the feature
/// that can be got subtly wrong without anything looking broken: a crop that
/// is a few pixels off center, or centered on the wrong axis, still produces a
/// file of exactly the requested shape. `CropGeometryTests` is therefore the
/// suite that says whether a bad output is the geometry's fault or the
/// encoder's.
enum CropGeometry {

    /// The largest centered rectangle of `aspect` that fits inside `size`, or
    /// the whole of `size` when `aspect` is `nil`.
    ///
    /// The comparison is a cross multiplication rather than a division, which
    /// is what makes the shape exact: 16:9 of a 1080-tall image comes out 1920
    /// wide, instead of 1919 because a division landed a fraction low. The
    /// rounding that remains is half-up on the single derived side.
    ///
    /// **An odd leftover goes to the right and the bottom**, because the
    /// integer division in the origin truncates. That is at most half a pixel
    /// off center, it is what every other center crop does, and it is pinned
    /// by test so it cannot drift into the other half pixel unnoticed.
    ///
    /// The result is never zero-width or zero-height: a 3×1 image asked for
    /// 1:16 comes back 1×1, not 0×1. `CGImage.cropping(to:)` returns nil for a
    /// zero-area rectangle, which would fail the file for something the user
    /// cannot act on, and a zero-area image is not an image.
    ///
    /// A non-positive aspect is treated as no crop rather than as an error.
    /// Neither front end can produce one — `CropField` requires both sides and
    /// `--crop` refuses them at parse time — so this is a floor under a value
    /// that should never arrive, not a second opinion about what is valid.
    static func centeredCrop(in size: PixelSize, aspect: AspectRatio?) -> CGRect {
        let width = max(1, size.width)
        let height = max(1, size.height)
        let whole = CGRect(x: 0, y: 0, width: width, height: height)

        guard let aspect, aspect.width > 0, aspect.height > 0 else { return whole }

        // width / height  vs  aspect.width / aspect.height, without dividing.
        let source = width * aspect.height
        let target = height * aspect.width

        var cropWidth = width
        var cropHeight = height
        if source > target {
            // Wider than the target: the height is the limit, so the sides
            // come off.
            cropWidth = min(width, max(1, divideRoundingHalfUp(height * aspect.width, by: aspect.height)))
        } else if source < target {
            // Taller than the target: the width is the limit.
            cropHeight = min(height, max(1, divideRoundingHalfUp(width * aspect.height, by: aspect.width)))
        }

        return CGRect(
            x: (width - cropWidth) / 2,
            y: (height - cropHeight) / 2,
            width: cropWidth,
            height: cropHeight
        )
    }

    /// The same question asked of a `CGImage`'s own dimensions.
    ///
    /// `ImageIOCompressor` uses this rather than the planner's rectangle,
    /// because `kCGImageSourceThumbnailMaxPixelSize` is a bound and not an
    /// exact request — the decoded image can land a pixel either side of what
    /// was predicted for it, and the crop has to be centered on the pixels
    /// actually in hand.
    static func centeredCrop(inImageOfWidth width: Int, height: Int, aspect: AspectRatio?) -> CGRect {
        centeredCrop(in: PixelSize(width: width, height: height), aspect: aspect)
    }

    /// Integer division rounding halves away from zero. Both arguments are
    /// positive at every call site above.
    private static func divideRoundingHalfUp(_ value: Int, by divisor: Int) -> Int {
        (value + divisor / 2) / divisor
    }
}
