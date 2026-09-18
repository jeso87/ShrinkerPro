import XCTest
import CoreGraphics
@testable import ShrinkerPro

/// The single value every compressor is handed when a file's pixels have to
/// change shape or size.
///
/// Worth its own suite because two of its three useful properties are derived,
/// and the derivation is where a crop would go wrong invisibly: `decodeScale`
/// decides how much of the image is even read off disk, and getting it a
/// fraction too small would crop from an image that had already lost the
/// pixels the crop wanted.
final class ResizePlanTests: XCTestCase {

    private func plan(
        source: (Int, Int), aspect: (Int, Int)?, output: (Int, Int)
    ) -> ResizePlan {
        ResizePlan(
            sourceSize: PixelSize(width: source.0, height: source.1),
            aspect: aspect.map { AspectRatio(width: $0.0, height: $0.1) },
            outputSize: PixelSize(width: output.0, height: output.1)
        )
    }

    // MARK: - The rectangle

    /// With no aspect the plan is a pure resize, and the rectangle is the whole
    /// frame. This is the max-size-only case — everything the app did before
    /// the crop existed — so it must not start reporting a crop.
    func testAPlanWithNoAspectIsNotCropping() {
        let resize = plan(source: (4000, 3000), aspect: nil, output: (2000, 1500))
        XCTAssertEqual(resize.cropRect, CGRect(x: 0, y: 0, width: 4000, height: 3000))
        XCTAssertFalse(resize.isCropping)
    }

    /// A source already the target shape is not cropped either, even though an
    /// aspect was asked for. The engine reads this to decide the file needs no
    /// rework at all.
    func testASourceAlreadyTheTargetShapeIsNotCropping() {
        XCTAssertFalse(plan(source: (600, 600), aspect: (1, 1), output: (600, 600)).isCropping)
        XCTAssertFalse(plan(source: (1920, 1080), aspect: (16, 9), output: (1920, 1080)).isCropping)
    }

    func testASourceOfADifferentShapeIsCropping() {
        let resize = plan(source: (1000, 500), aspect: (1, 1), output: (500, 500))
        XCTAssertTrue(resize.isCropping)
        XCTAssertEqual(resize.cropRect, CGRect(x: 250, y: 0, width: 500, height: 500))
    }

    // MARK: - The decode scale

    /// Scaling the whole image by the factor the *crop* needs leaves the crop
    /// at exactly its finished size. Here: a 4000×3000 photo cropped square is
    /// a 3000×3000 rectangle, and asking for 1500×1500 means halving it — so
    /// the whole image decodes at half size, 2000×1500, not at 1500 wide.
    ///
    /// Getting this backwards by using the output against the *source* rather
    /// than the crop would decode 1500/4000 of the image and then crop a
    /// square out of something already too small.
    func testTheDecodeScaleIsMeasuredAgainstTheCropNotTheSource() {
        let resize = plan(source: (4000, 3000), aspect: (1, 1), output: (1500, 1500))
        XCTAssertEqual(resize.cropRect.width, 3000)
        XCTAssertEqual(resize.decodeScale, 0.5, accuracy: 0.0001)
        // The decode this implies still covers the crop.
        let decodedLongestSide = Double(resize.sourceSize.longestSide) * resize.decodeScale
        XCTAssertGreaterThanOrEqual(decodedLongestSide, 1500)
    }

    /// Ratio-only mode does no scaling, so nothing is gained by decoding small
    /// and the factor is exactly 1. Correct rather than a missed optimisation:
    /// the output genuinely is those pixels.
    func testRatioOnlyModeDecodesAtFullSize() {
        let resize = plan(source: (4000, 3000), aspect: (1, 1), output: (3000, 3000))
        XCTAssertEqual(resize.decodeScale, 1, accuracy: 0.0001)
    }

    /// The factor never exceeds 1, whatever it is asked for. A plan should
    /// never contain an output larger than its crop — the engine clamps that —
    /// but this is the last place an enlargement could slip through into a
    /// decode, so it refuses one here too.
    func testTheDecodeScaleNeverAsksForAnEnlargement() {
        let resize = plan(source: (800, 600), aspect: (1, 1), output: (4000, 4000))
        XCTAssertEqual(resize.decodeScale, 1, accuracy: 0.0001)
    }

    /// A plain resize with no crop scales by the obvious factor, so the
    /// max-size path keeps decoding exactly as much as it did before.
    func testAPlainResizeScalesByTheObviousFactor() {
        let resize = plan(source: (4000, 2000), aspect: nil, output: (2000, 1000))
        XCTAssertEqual(resize.decodeScale, 0.5, accuracy: 0.0001)
    }

    /// The scale is the same whichever way round the source is, because
    /// rotating swaps the axes without changing the ratio between two lengths.
    /// This is the property that lets the crop keep the thumbnail decode
    /// without worrying about orientation.
    func testTheDecodeScaleIsUnchangedByRotatingTheSource() {
        let landscape = plan(source: (4000, 3000), aspect: (1, 1), output: (750, 750))
        let portrait = plan(source: (3000, 4000), aspect: (1, 1), output: (750, 750))
        XCTAssertEqual(landscape.decodeScale, portrait.decodeScale, accuracy: 0.0001)
    }
}
