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
        XCTAssertEqual(QualityLevel.allCases, [.superLow, .low, .standard, .high])
    }

    /// Super Low exists because the gap below Low is where the remaining
    /// savings are, measured on a real 18.3MB camera original:
    ///
    ///     cjpeg 60 (Low)       2.19 MB   -88%
    ///     cjpeg 40 (Super Low) ~1.6 MB   -91%
    ///     cjpeg 35             1.46 MB   -92%
    ///
    /// It must sit strictly below Low on every axis, or it is just a second
    /// name for the same setting.
    func testSuperLowSitsBelowLowOnEveryEncoderAxis() throws {
        let superLow = QualityLevel.superLow.settings
        let low = QualityLevel.low.settings

        XCTAssertLessThan(superLow.unitScale, low.unitScale)
        XCTAssertLessThan(superLow.cwebpScale, low.cwebpScale)
        XCTAssertLessThan(try XCTUnwrap(superLow.cjpegQuality), try XCTUnwrap(low.cjpegQuality))
    }

    /// Both pickers that will offer this — the window footer and the
    /// Settings row — render `ForEach(QualityLevel.allCases)`, so these
    /// strings *are* the on-screen option list. Same reasoning
    /// `SettingsViewTests` applies to the conversion enums: there is no
    /// separate options structure that could drift from what's rendered.
    ///
    /// "Standard" rather than "Default" is deliberate. The session-override
    /// dropdown sits immediately beside this one in the footer and its
    /// no-override entry reads "App default"; two adjacent menus both
    /// offering a "Default" would be needlessly ambiguous about which
    /// default is meant.
    func testDisplayNamesReadWorstToBest() {
        XCTAssertEqual(
            QualityLevel.allCases.map(\.displayName),
            ["Super Low", "Low", "Standard", "High"]
        )
    }

    /// ImageIO's AVIF encoder fails outright at exactly 1.0 —
    /// `CGImageDestinationFinalize` returns false and writes nothing — so
    /// `--quality 100 --to avif` died with `conversionFailed` and exit 7 for
    /// a value `--help` advertises as valid. Measured: 0.99 and 0.999 encode
    /// fine, 1.0 produces 0 bytes. HEIC is unaffected.
    ///
    /// The cap belongs to this axis alone: cjpeg and cwebp both take their
    /// full range, and quietly lowering what a caller asked those encoders
    /// for would be a separate bug.
    func testANumericQualityOf100DoesNotReachImageIOsFailurePoint() throws {
        let resolved = QualityChoice.numeric(100).settings

        XCTAssertLessThan(
            resolved.unitScale, 1.0,
            "ImageIO's AVIF encoder writes zero bytes at exactly 1.0"
        )
        XCTAssertEqual(resolved.cwebpScale, 100, "cwebp's own range must not be clamped")
        XCTAssertEqual(resolved.cjpegQuality, 100, "cjpeg's own range must not be clamped")
    }

    /// mozjpeg's `set_quality_ratings` also picks chroma subsampling, and it
    /// switches from 4:2:0 to 4:4:4 at quality >= 90 — a discontinuity, not a
    /// gradient. Measured against this project's own 45,784-byte fixture:
    ///
    ///     quality 88 -> 37,739 bytes  (-18% vs the original)
    ///     quality 90 -> 50,467 bytes  (+10% vs the original)
    ///
    /// A 34% jump for two points of quality. `.high` must stay on the near
    /// side of that cliff so nobody falls off it by choosing the top setting.
    func testHighStaysBelowMozjpegsSubsamplingCliff() throws {
        let high = try XCTUnwrap(QualityLevel.high.settings.cjpegQuality)
        XCTAssertLessThan(
            high, 90,
            "cjpeg switches to 4:4:4 subsampling at quality >= 90, inflating output by ~34% in one step"
        )
    }
}
