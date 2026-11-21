import CoreGraphics
import Foundation

/// One of the eight ways a photo can lie: mirrored left to right or not, then turned clockwise
/// by whole quarters. Applied after the file's own orientation, so everything downstream works
/// on the turned photo as if it had been taken that way. The result list's Rotate Left and
/// Rotate Right use it, and Studio's Rotate & straighten.
///
/// Quarter turns and mirrors are exact: nothing is resampled or lost, and coordinates map
/// through them without rounding.
struct PhotoTurn: Equatable, Hashable, Codable, Sendable {
    /// Clockwise quarter turns, 0...3.
    private(set) var quarters: Int
    /// Mirrored left to right before the turn.
    private(set) var mirrored: Bool

    init(quarters: Int = 0, mirrored: Bool = false) {
        self.quarters = ((quarters % 4) + 4) % 4
        self.mirrored = mirrored
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            quarters: try container.decodeIfPresent(Int.self, forKey: .quarters) ?? 0,
            mirrored: try container.decodeIfPresent(Bool.self, forKey: .mirrored) ?? false
        )
    }

    static let identity = PhotoTurn()

    var isIdentity: Bool { quarters == 0 && !mirrored }
    /// Whether width and height trade places.
    var swapsSides: Bool { quarters % 2 == 1 }

    // MARK: Composing

    /// The photo as it is now, turned a further quarter clockwise.
    var rotatedRight: PhotoTurn { PhotoTurn(quarters: quarters + 1, mirrored: mirrored) }
    /// The photo as it is now, turned a further quarter counter-clockwise.
    var rotatedLeft: PhotoTurn { PhotoTurn(quarters: quarters + 3, mirrored: mirrored) }
    /// The photo as it is now, turned half way round.
    var rotatedHalf: PhotoTurn { PhotoTurn(quarters: quarters + 2, mirrored: mirrored) }
    /// The photo as it is now, mirrored left to right. A mirror after a turn is the reverse
    /// turn after a mirror.
    var flippedHorizontally: PhotoTurn { PhotoTurn(quarters: -quarters, mirrored: !mirrored) }
    /// The photo as it is now, mirrored top to bottom: a left-right mirror, then a half turn.
    var flippedVertically: PhotoTurn { flippedHorizontally.rotatedHalf }

    /// `self`, then `next`, as one turn.
    func then(_ next: PhotoTurn) -> PhotoTurn {
        var result = self
        if next.mirrored { result = result.flippedHorizontally }
        return PhotoTurn(quarters: result.quarters + next.quarters, mirrored: result.mirrored)
    }

    /// The turn that undoes this one.
    var inverse: PhotoTurn {
        mirrored ? self : PhotoTurn(quarters: -quarters, mirrored: false)
    }

    // MARK: Sizes and coordinates

    func size(_ size: CGSize) -> CGSize {
        swapsSides ? CGSize(width: size.height, height: size.width) : size
    }

    func size(_ size: PixelSize) -> PixelSize {
        swapsSides ? PixelSize(width: size.height, height: size.width) : size
    }

    /// A point in unit coordinates of the photo before the turn (top-left origin, y down),
    /// where it lands after it.
    func unitPoint(x: Double, y: Double) -> (x: Double, y: Double) {
        var point = (x: mirrored ? 1 - x : x, y: y)
        for _ in 0..<quarters { point = (x: 1 - point.y, y: point.x) }
        return point
    }

    /// A rectangle in pixels of a photo `size` before the turn, in the turned photo's pixels.
    func map(_ rect: CGRect, in size: CGSize) -> CGRect {
        guard !isIdentity else { return rect }
        // In pixels, not unit coordinates, so whole pixels stay whole.
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            var p = CGPoint(x: mirrored ? size.width - x : x, y: y)
            var height = size.height
            var width = size.width
            for _ in 0..<quarters {
                p = CGPoint(x: height - p.y, y: p.x)
                swap(&width, &height)
            }
            return p
        }
        let a = point(rect.minX, rect.minY), b = point(rect.maxX, rect.maxY)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    // MARK: Pixels

    /// `image` turned. The identity gives the same image back; anything else redraws it once,
    /// at its own size, with no interpolation (quarter turns land on whole pixels).
    func apply(to image: CGImage) -> CGImage? {
        guard !isIdentity else { return image }
        let width = image.width, height = image.height
        let out = size(CGSize(width: width, height: height))
        let space = image.colorSpace.flatMap { $0.model == .rgb || $0.model == .monochrome ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let alpha = image.alphaInfo
        let hasAlpha = !(alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast)
        let bits = image.bitsPerComponent > 8 ? 16 : 8
        var info: UInt32
        if space.model == .monochrome && !hasAlpha {
            info = CGImageAlphaInfo.none.rawValue
        } else {
            info = (hasAlpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue
        }
        if bits == 16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        guard let context = CGContext(
            data: nil, width: Int(out.width), height: Int(out.height), bitsPerComponent: bits, bytesPerRow: 0,
            space: space, bitmapInfo: info
        ) ?? CGContext(
            data: nil, width: Int(out.width), height: Int(out.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.concatenate(drawingTransform(width: Double(width), height: Double(height)))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// The transform, in Core Graphics' bottom-left coordinates, that draws the photo's rect
    /// `0, 0, width, height` turned into the output's.
    func drawingTransform(width: Double, height: Double) -> CGAffineTransform {
        // In top-left coordinates: mirror, then each clockwise quarter (x, y) → (h − y, x),
        // where h is the height at that point.
        var transform = CGAffineTransform.identity
        var w = width, h = height
        if mirrored { transform = transform.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)) }
        for _ in 0..<quarters {
            transform = transform.concatenating(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0))
            swap(&w, &h)
        }
        // Core Graphics is y up: flip into top-left on the way in and out of it.
        let into = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
        let outOf = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        return into.concatenating(transform).concatenating(outOf)
    }
}
