import XCTest
@testable import ShrinkerPro

/// The quality model, at the level where it is pure: a `QualityLevel` maps to
/// the three encoder-specific numbers the compressors actually take. Nothing
/// here touches disk or a helper binary — the end-to-end proof that these
/// numbers reach the encoders lives in `ShrinkEngineTests`.
final class ConversionQualityTests: XCTestCase {

    /// The whole safety of making quality selectable: `.standard` must
    /// resolve to exactly the constants this app already ships, or every
    /// existing user's output changes silently the moment they upgrade.
    ///
    /// `cjpegQuality` is `nil` rather than 75 on purpose, and that is not a
    /// missing value. mozjpeg's `set_quality_ratings` also sets default
    /// subsampling (vendor/src/mozjpeg/cjpeg.c:673), so passing an explicit
    /// `-quality 75` is *not* equivalent to passing nothing — even though 75
    /// is cjpeg's own built-in default (cjpeg.c:521). Omitting the flag is
    /// the only thing that reproduces today's JPEG bytes.
    func testStandardResolvesToTheConstantsTheAppAlreadyShips() {
        let resolved = QualityLevel.standard.settings

        XCTAssertEqual(resolved.unitScale, 0.80, accuracy: 0.0001)
        XCTAssertEqual(resolved.cwebpScale, 80)
        XCTAssertNil(
            resolved.cjpegQuality,
            "Standard must omit cjpeg's -quality flag entirely, not pass 75 — "
                + "mozjpeg changes subsampling as a side effect of an explicit -quality"
        )
    }

    /// Pins the *direction* of the mapping rather than three arbitrary
    /// numbers, so the numbers stay tunable while a swapped low/high — the
    /// easy mistake, and an invisible one, since both still produce valid
    /// images — fails here.
    ///
    /// The cjpeg axis is the interesting one: `.standard` names no value at
    /// all, so low and high are checked against the 75 cjpeg would have
    /// applied on its own (vendor/src/mozjpeg/cjpeg.c:521). A `.low` above
    /// 75 or a `.high` below it would mean the level moved JPEG output the
    /// opposite way from every other format.
    func testLowAndHighBracketStandardOnEveryEncoderAxis() throws {
        let low = QualityLevel.low.settings
        let standard = QualityLevel.standard.settings
        let high = QualityLevel.high.settings

        XCTAssertLessThan(low.unitScale, standard.unitScale)
        XCTAssertLessThan(standard.unitScale, high.unitScale)

        XCTAssertLessThan(low.cwebpScale, standard.cwebpScale)
        XCTAssertLessThan(standard.cwebpScale, high.cwebpScale)

        XCTAssertLessThan(
            try XCTUnwrap(low.cjpegQuality), 75,
            "Low must sit below the 75 cjpeg applies when the flag is omitted"
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(high.cjpegQuality), 75,
            "High must sit above the 75 cjpeg applies when the flag is omitted"
        )
    }

    /// The picker in Settings renders `ForEach(QualityLevel.allCases)`, so
    /// `allCases` *is* the option list and its order is the on-screen order —
    /// the same reasoning `SettingsViewTests` applies to the conversion
    /// enums. Worst to best, so the control reads left-to-right the way the
    /// values do.
    func testAllCasesAreOrderedWorstToBest() {
        XCTAssertEqual(QualityLevel.allCases, [.low, .standard, .high])
    }
}
