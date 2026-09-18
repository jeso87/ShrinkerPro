import XCTest
import CoreGraphics
@testable import ShrinkerPro

/// The arithmetic at the heart of the center crop: which rectangle comes out
/// of an image of a given size for a given target shape.
///
/// Pure and IO-free, and tested here rather than through the engine because
/// every end-to-end crop test in `ShrinkEngineTests` is really a test of this
/// function plus an encoder. When a cropped file comes out the wrong shape,
/// this is the suite that says whether the geometry or the plumbing is at
/// fault.
///
/// See `2026-09-17-center-crop-design.md` §1 and §4.
final class CropGeometryTests: XCTestCase {

    private func crop(_ w: Int, _ h: Int, _ aw: Int, _ ah: Int) -> CGRect {
        CropGeometry.centeredCrop(
            in: PixelSize(width: w, height: h), aspect: AspectRatio(width: aw, height: ah)
        )
    }

    // MARK: - No crop at all

    /// A `nil` aspect is the max-size-only case — everything this app did
    /// before the crop existed — and must hand back the whole frame untouched.
    func testANilAspectReturnsTheWholeFrame() {
        XCTAssertEqual(
            CropGeometry.centeredCrop(in: PixelSize(width: 1000, height: 500), aspect: nil),
            CGRect(x: 0, y: 0, width: 1000, height: 500)
        )
    }

    /// A source already the target shape is not cropped at all, rather than
    /// cropped to an identical rectangle by a different route. The engine
    /// reads this to decide the file needs no rework, so an off-by-one here
    /// would re-encode every square image someone asked to crop square.
    func testASourceAlreadyTheTargetShapeIsUntouched() {
        XCTAssertEqual(crop(600, 600, 1, 1), CGRect(x: 0, y: 0, width: 600, height: 600))
        XCTAssertEqual(crop(1920, 1080, 16, 9), CGRect(x: 0, y: 0, width: 1920, height: 1080))
        // The same shape expressed differently must behave identically.
        XCTAssertEqual(crop(1920, 1080, 1920, 1080), CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    // MARK: - The rectangle

    /// Landscape cropped square: the height is the limit, and the sides come
    /// off evenly.
    func testALandscapeSourceCroppedSquareLosesItsSides() {
        XCTAssertEqual(crop(1000, 500, 1, 1), CGRect(x: 250, y: 0, width: 500, height: 500))
    }

    /// Portrait cropped square: the width is the limit, and the rectangle is
    /// centered vertically.
    func testAPortraitSourceCroppedSquareLosesItsTopAndBottom() {
        XCTAssertEqual(crop(500, 1000, 1, 1), CGRect(x: 0, y: 250, width: 500, height: 500))
    }

    /// The rule the feature is most likely to be asked about, and the one a
    /// future change is most likely to "fix": the target is applied literally,
    /// so a portrait photo cropped to 16:9 comes out as a landscape strip
    /// rather than being flipped to 9:16 to suit the source.
    ///
    /// See `2026-09-17-center-crop-design.md` §1.
    func testAPortraitSourceCroppedTo16By9ComesOutLandscape() {
        let rect = crop(500, 1000, 16, 9)
        XCTAssertEqual(rect.width, 500)
        XCTAssertEqual(rect.height, 281)
        XCTAssertGreaterThan(rect.width, rect.height, "16:9 must stay landscape")
        XCTAssertEqual(rect.minX, 0)
        XCTAssertEqual(rect.minY, 359)
    }

    /// And the mirror of it, so the pair documents that neither orientation is
    /// special-cased.
    func testALandscapeSourceCroppedTo9By16ComesOutPortrait() {
        let rect = crop(1000, 500, 9, 16)
        XCTAssertEqual(rect.height, 500)
        XCTAssertEqual(rect.width, 281)
        XCTAssertLessThan(rect.width, rect.height, "9:16 must stay portrait")
    }

    /// Exact arithmetic, not floating point: 16:9 of a 1080-tall image is 1920
    /// wide, never 1919 because a division landed a fraction low.
    func testTheShapeIsExactRatherThanRounded() {
        XCTAssertEqual(crop(4000, 1080, 16, 9), CGRect(x: 1040, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(crop(1080, 4000, 9, 16), CGRect(x: 0, y: 1040, width: 1080, height: 1920))
    }

    // MARK: - Edges

    /// An odd number of leftover pixels cannot be split evenly. It goes to the
    /// right and the bottom — at most half a pixel off center — and is pinned
    /// here so it cannot drift silently into the other half pixel.
    func testAnOddLeftoverFallsToTheRightAndBottom() {
        XCTAssertEqual(crop(101, 100, 1, 1), CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(crop(100, 101, 1, 1), CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    /// A crop can never have zero area. A 3×1 image asked for 1:16 wants a
    /// rectangle a fraction of a pixel tall, and a zero-height image is not an
    /// image — `CGImage.cropping(to:)` returns nil for it and the file would
    /// fail for something the user cannot act on.
    func testADegenerateShapeStillYieldsAtLeastOnePixel() {
        for (w, h, aw, ah) in [(3, 1, 1, 16), (1, 3, 16, 1), (1, 1, 16, 9), (1, 1, 9, 16)] {
            let rect = crop(w, h, aw, ah)
            XCTAssertGreaterThanOrEqual(rect.width, 1, "\(w)x\(h) at \(aw):\(ah)")
            XCTAssertGreaterThanOrEqual(rect.height, 1, "\(w)x\(h) at \(aw):\(ah)")
        }
    }

    /// A nonsensical aspect — zero or negative on either side — is treated as
    /// no crop rather than as an error. Neither front end can produce one
    /// (`CropField` rejects it, `--crop` refuses it at parse time), so this is
    /// a floor under a value that should never arrive.
    func testANonsenseAspectIsTreatedAsNoCrop() {
        let whole = CGRect(x: 0, y: 0, width: 400, height: 300)
        XCTAssertEqual(crop(400, 300, 0, 1), whole)
        XCTAssertEqual(crop(400, 300, 1, 0), whole)
        XCTAssertEqual(crop(400, 300, -16, 9), whole)
    }

    // MARK: - Properties

    /// Cropping a crop of the same shape changes nothing. Stated because the
    /// engine relies on it: a file already the target shape must decide it
    /// needs no rework, and that decision is this equality.
    func testCroppingIsIdempotent() {
        for (w, h) in [(1000, 500), (500, 1000), (637, 637), (1920, 1080)] {
            let once = crop(w, h, 4, 5)
            let twice = CropGeometry.centeredCrop(
                in: PixelSize(width: Int(once.width), height: Int(once.height)),
                aspect: AspectRatio(width: 4, height: 5)
            )
            XCTAssertEqual(twice.width, once.width, "\(w)x\(h)")
            XCTAssertEqual(twice.height, once.height, "\(w)x\(h)")
        }
    }

    /// The rectangle is always inside the frame and always at least a pixel,
    /// for every small size against a spread of shapes. A crop that escaped
    /// its frame would be a `cropping(to:)` returning nil, and the sweep is
    /// what stops a rounding change turning one size into that.
    func testEveryRectangleStaysInsideItsFrame() {
        let aspects = [(1, 1), (16, 9), (9, 16), (4, 5), (3, 2), (1, 16), (16, 1)]
        for w in 1...40 {
            for h in 1...40 {
                for (aw, ah) in aspects {
                    let rect = crop(w, h, aw, ah)
                    XCTAssertGreaterThanOrEqual(rect.minX, 0, "\(w)x\(h) @ \(aw):\(ah)")
                    XCTAssertGreaterThanOrEqual(rect.minY, 0, "\(w)x\(h) @ \(aw):\(ah)")
                    XCTAssertLessThanOrEqual(rect.maxX, CGFloat(w), "\(w)x\(h) @ \(aw):\(ah)")
                    XCTAssertLessThanOrEqual(rect.maxY, CGFloat(h), "\(w)x\(h) @ \(aw):\(ah)")
                    XCTAssertGreaterThanOrEqual(rect.width, 1, "\(w)x\(h) @ \(aw):\(ah)")
                    XCTAssertGreaterThanOrEqual(rect.height, 1, "\(w)x\(h) @ \(aw):\(ah)")
                }
            }
        }
    }
}
