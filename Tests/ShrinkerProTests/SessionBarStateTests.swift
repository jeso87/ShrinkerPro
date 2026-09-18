import XCTest
@testable import ShrinkerPro

/// The session bar's conditional behaviour, factored out of `SessionBarView`
/// for the same reason `RecentHeaderFormatter` was factored out of
/// `RecentHeaderView`: this project has no view-tree testing dependency, so
/// logic left inline in a `body` is logic nothing can assert on.
///
/// It earns the separation twice over now that the bar collapses: the
/// summary line is the only statement of what the session will do when the
/// controls are hidden, so a wrong one is invisible rather than obvious.
final class SessionBarStateTests: XCTestCase {

    // MARK: - The growth warning

    func testGrowthWarningShowsOnlyForPNG() {
        XCTAssertTrue(SessionBarState.showsGrowthWarning(for: .png))

        for format in [SessionFormat.jpeg, .webp, .avif] {
            XCTAssertFalse(
                SessionBarState.showsGrowthWarning(for: format),
                "\(format.displayName) is lossy — it has no growth to warn about"
            )
        }
    }

    /// No override means no warning: with the bar showing "App default" there
    /// is nothing surprising in play to explain.
    func testGrowthWarningIsHiddenWithNoOverride() {
        XCTAssertFalse(SessionBarState.showsGrowthWarning(for: nil))
    }

    /// Guards the reason this is a warning at all. If a second lossless
    /// target is ever added to `SessionFormat`, it will need its own growth
    /// warning, and this fails until someone decides that deliberately.
    func testExactlyOneFormatWarnsAboutGrowth() {
        let warning = SessionFormat.allCases.filter { SessionBarState.showsGrowthWarning(for: $0) }
        XCTAssertEqual(
            warning, [.png],
            "a newly-added lossless conversion target needs its own growth warning"
        )
    }

    /// The glyph holds its space permanently so the row's height never shifts
    /// when the override changes — which means that while it is invisible it
    /// is still a hover target. Empty help text is what stops it showing a
    /// tooltip for a glyph nobody can see.
    func testHelpTextIsEmptyWhileTheWarningIsInvisible() {
        XCTAssertTrue(SessionBarState.growthWarningHelp(for: nil).isEmpty)
        XCTAssertTrue(SessionBarState.growthWarningHelp(for: .jpeg).isEmpty)
        XCTAssertFalse(SessionBarState.growthWarningHelp(for: .png).isEmpty)
    }

    // MARK: - Is anything overridden

    func testNothingSetIsNotModified() {
        XCTAssertFalse(
            SessionBarState.isModified(
                format: nil, quality: nil, storedQuality: .standard, maxDimension: nil, crop: nil
            )
        )
    }

    func testAnyOneSettingMakesItModified() {
        XCTAssertTrue(
            SessionBarState.isModified(
                format: .webp, quality: nil, storedQuality: .standard, maxDimension: nil, crop: nil
            ),
            "a format override"
        )
        XCTAssertTrue(
            SessionBarState.isModified(
                format: nil, quality: .high, storedQuality: .standard, maxDimension: nil, crop: nil
            ),
            "a quality that differs from the stored default"
        )
        XCTAssertTrue(
            SessionBarState.isModified(
                format: nil, quality: nil, storedQuality: .standard, maxDimension: 2000, crop: nil
            ),
            "a max size"
        )
    }

    /// "Modified" means "doing something your settings would not". Someone
    /// whose stored quality is High and who has not touched the bar is not
    /// overriding anything, and must not be shown a dot and a Reset for it.
    func testMatchingTheStoredQualityIsNotAnOverride() {
        XCTAssertFalse(
            SessionBarState.isModified(
                format: nil, quality: .high, storedQuality: .high, maxDimension: nil, crop: nil
            )
        )
        XCTAssertTrue(
            SessionBarState.isModified(
                format: nil, quality: .standard, storedQuality: .high, maxDimension: nil, crop: nil
            ),
            "choosing Standard when the stored default is High IS an override"
        )
    }

    // MARK: - The summary line

    func testTheDefaultSummaryNamesTheDefaults() {
        XCTAssertEqual(
            SessionBarState.summary(
                format: nil, quality: nil, storedQuality: .standard, maxDimension: nil, crop: nil
            ),
            "App default · Standard · No limit"
        )
    }

    func testTheSummaryStatesEverySessionValue() {
        XCTAssertEqual(
            SessionBarState.summary(
                format: .webp, quality: .high, storedQuality: .standard, maxDimension: 2000, crop: nil
            ),
            "WebP · High · Max 2000px"
        )
    }

    /// The summary shows what will actually happen, so an untouched quality
    /// reads as the stored default rather than as a fixed "Standard".
    func testAnUntouchedQualityShowsTheStoredDefault() {
        XCTAssertEqual(
            SessionBarState.summary(
                format: nil, quality: nil, storedQuality: .superLow, maxDimension: nil, crop: nil
            ),
            "App default · Super Low · No limit"
        )
    }

    /// Every quality level has to be sayable in the summary, since the bar is
    /// the only place some users will ever read it back.
    func testEveryQualityLevelAppearsInTheSummary() {
        for level in QualityLevel.allCases {
            XCTAssertTrue(
                SessionBarState.summary(
                    format: nil, quality: level, storedQuality: .standard, maxDimension: nil, crop: nil
                )
                .contains(level.displayName),
                "\(level) is missing from its own summary"
            )
        }
    }

    // MARK: - Narrow windows

}

/// The max size field's rules. They live in `MaxSizeField` rather than in a
/// `TextField` formatter precisely so they can be checked here — see that
/// type's own comment.
final class MaxSizeFieldTests: XCTestCase {

    func testOnlyDigitsSurvive() {
        XCTAssertEqual(MaxSizeField.filter("2000"), "2000")
        XCTAssertEqual(MaxSizeField.filter("2a0b0c0"), "2000")
        XCTAssertEqual(MaxSizeField.filter("1,920"), "1920")
        XCTAssertEqual(MaxSizeField.filter("-500"), "500")
        XCTAssertEqual(MaxSizeField.filter("12.5"), "125")
    }

    /// Pasting a padded number should leave the number, not refuse the paste.
    func testLeadingZerosAreDropped() {
        XCTAssertEqual(MaxSizeField.filter("02000"), "2000")
        XCTAssertEqual(MaxSizeField.filter("0000"), "")
    }

    func testTheFieldIsBoundedInLength() {
        XCTAssertEqual(MaxSizeField.filter("123456789"), "12345")
    }

    /// Idempotence is what makes it safe to run from the `didSet` that
    /// assigns back to the property it observes — see `AppModel`.
    func testFilteringIsIdempotent() {
        for text in ["", "0", "2000", "9x9x9", "000123456"] {
            XCTAssertEqual(
                MaxSizeField.filter(MaxSizeField.filter(text)), MaxSizeField.filter(text),
                "filtering \"\(text)\" twice changed it"
            )
        }
    }

    /// Blank and zero are the same instruction: no resizing. Neither may
    /// leave a cap quietly in force.
    func testBlankAndZeroBothMeanNoResizing() {
        XCTAssertNil(MaxSizeField.dimension(from: ""))
        XCTAssertNil(MaxSizeField.dimension(from: "0"))
        XCTAssertNil(MaxSizeField.dimension(from: "00"))
        XCTAssertNil(MaxSizeField.dimension(from: "px"))
    }

    func testAValueIsRead() {
        XCTAssertEqual(MaxSizeField.dimension(from: "2000"), 2000)
        XCTAssertEqual(MaxSizeField.dimension(from: "1"), 1)
    }

    /// The engine can never be handed a cap outside the range, whatever is in
    /// the field.
    func testAnOutOfRangeValueIsClamped() {
        XCTAssertEqual(MaxSizeField.dimension(from: "99999"), MaxSizeField.maximum)
        XCTAssertEqual(MaxSizeField.dimension(from: "20001"), MaxSizeField.maximum)
        XCTAssertEqual(MaxSizeField.dimension(from: "20000"), 20_000)
    }

    /// The text itself is only snapped when editing ends — rewriting it
    /// mid-keystroke would fight anyone typing "20000" one digit at a time,
    /// since "2" is in range, "20" is, and so on.
    func testTextIsSnappedOnlyOnCommit() {
        XCTAssertEqual(MaxSizeField.filter("99999"), "99999", "left alone while typing")
        XCTAssertEqual(MaxSizeField.committed("99999"), "20000", "snapped when editing ends")
        XCTAssertEqual(MaxSizeField.committed("2000"), "2000")
        XCTAssertEqual(MaxSizeField.committed("0"), "", "zero commits to the off state")
        XCTAssertEqual(MaxSizeField.committed(""), "")
    }
}

/// `CropField`, and the parts of `SessionBarState` the crop row drives.
///
/// Its own class rather than an appendix to `MaxSizeFieldTests`: the two
/// fields share their keystroke rules deliberately, and one test here asserts
/// exactly that, but everything else about a crop is its own subject.
final class CropFieldTests: XCTestCase {

    // MARK: - The crop

    private func pixels(_ w: Int, _ h: Int) -> CropTarget {
        CropTarget(width: w, height: h, mode: .pixels)
    }

    private func ratio(_ w: Int, _ h: Int) -> CropTarget {
        CropTarget(width: w, height: h, mode: .ratio)
    }

    /// The separator is the whole difference between "a 1200 by 1200 image"
    /// and "a square, whatever size the source allows", and the summary uses
    /// the same two glyphs the field does so the bar reads back as what was
    /// typed.
    func testTheSummaryDistinguishesThePixelAndRatioModes() {
        XCTAssertEqual(SessionBarState.cropFragment(pixels(1200, 1200)), "Crop 1200×1200")
        XCTAssertEqual(SessionBarState.cropFragment(ratio(1, 1)), "Crop 1:1")
        XCTAssertEqual(SessionBarState.cropFragment(ratio(16, 9)), "Crop 16:9")
    }

    func testTheSummaryStatesTheCropAlongsideEverythingElse() {
        XCTAssertEqual(
            SessionBarState.summary(
                format: .webp, quality: .high, storedQuality: .standard,
                maxDimension: 2000, crop: pixels(1200, 1200)
            ),
            "WebP · High · Max 2000px · Crop 1200×1200"
        )
    }

    /// The other three settings always state themselves, off values included.
    /// The crop does not, and that asymmetry is deliberate: a fourth "No crop"
    /// pushed the default summary past the width of the *default* window, and
    /// a line that truncates while saying nothing is worse than a shorter one.
    func testTheSummaryIsSilentWhenThereIsNoCrop() {
        let summary = SessionBarState.summary(
            format: nil, quality: nil, storedQuality: .standard,
            maxDimension: nil, crop: nil
        )
        XCTAssertEqual(summary, "App default · Standard · No limit")
        XCTAssertFalse(summary.lowercased().contains("crop"))
    }

    func testACropAloneMakesTheSessionModified() {
        XCTAssertTrue(
            SessionBarState.isModified(
                format: nil, quality: nil, storedQuality: .standard,
                maxDimension: nil, crop: ratio(1, 1)
            )
        )
    }

    // MARK: - Both sides are needed

    /// **A half-filled crop is no crop.** Otherwise someone types "1200", drags
    /// a folder in, and every file is cropped to a height nobody chose — the
    /// same failure the live parse was introduced to prevent, one field along,
    /// and worse: a wrong size can be redone from the original, a wrong crop
    /// has already thrown pixels away.
    func testOneSideAloneIsNotACrop() {
        XCTAssertNil(CropField.target(width: "1200", height: "", mode: .pixels))
        XCTAssertNil(CropField.target(width: "", height: "1200", mode: .pixels))
        XCTAssertNil(CropField.target(width: "", height: "", mode: .ratio))
        // Zero is the off state for a field, so it behaves as blank does.
        XCTAssertNil(CropField.target(width: "1200", height: "0", mode: .pixels))
    }

    func testBothSidesTogetherAreACrop() {
        XCTAssertEqual(
            CropField.target(width: "1200", height: "800", mode: .pixels),
            pixels(1200, 800)
        )
        XCTAssertEqual(
            CropField.target(width: "16", height: "9", mode: .ratio),
            ratio(16, 9)
        )
    }

    /// The hint's condition: exactly one side typed. Neither and both are
    /// settled states, and neither deserves a nag.
    func testTheHintAppearsOnlyWhileExactlyOneSideIsTyped() {
        XCTAssertTrue(CropField.isHalfFilled(width: "1200", height: ""))
        XCTAssertTrue(CropField.isHalfFilled(width: "", height: "800"))
        XCTAssertFalse(CropField.isHalfFilled(width: "", height: ""))
        XCTAssertFalse(CropField.isHalfFilled(width: "1200", height: "800"))
    }

    /// The three numeric fields in this panel share one set of rules, so a
    /// change to one cannot quietly leave the others behind.
    func testTheCropFieldsFilterExactlyAsTheMaxSizeFieldDoes() {
        for raw in ["12a3", "0012", "999999", "", "0", "  45  ", "1.5"] {
            XCTAssertEqual(CropField.filter(raw), MaxSizeField.filter(raw), raw)
            XCTAssertEqual(CropField.committed(raw), MaxSizeField.committed(raw), raw)
        }
    }

    func testAnOutOfRangeSideSnapsOnCommit() {
        XCTAssertEqual(CropField.committed("99999"), "20000")
    }

    // MARK: - When the cap beats the crop

    /// `Crop 1200×1200` with `Max 500px` produces a 500×500 file. That is the
    /// only coherent composition of the two, and a genuine surprise, so the
    /// bar says which number wins rather than letting it be discovered.
    func testTheWarningAppearsWhenTheCapIsSmallerThanTheCrop() {
        XCTAssertTrue(
            SessionBarState.capOverridesCrop(crop: pixels(1200, 1200), maxDimension: 500)
        )
        XCTAssertFalse(
            SessionBarState.capOverridesCrop(crop: pixels(1200, 1200), maxDimension: 2000)
        )
        XCTAssertFalse(
            SessionBarState.capOverridesCrop(crop: pixels(1200, 1200), maxDimension: nil)
        )
        XCTAssertFalse(
            SessionBarState.capOverridesCrop(crop: nil, maxDimension: 500)
        )
    }

    /// A cap equal to the crop's longest side overrides nothing — the crop
    /// already asks for exactly that.
    func testACapEqualToTheCropIsNotAnOverride() {
        XCTAssertFalse(
            SessionBarState.capOverridesCrop(crop: pixels(1200, 800), maxDimension: 1200)
        )
    }

    /// A ratio crop makes no promise about size, so a cap is not overriding
    /// anything — it is doing the only sizing there is.
    func testARatioCropIsNeverOverriddenByTheCap() {
        XCTAssertFalse(
            SessionBarState.capOverridesCrop(crop: ratio(1, 1), maxDimension: 10)
        )
    }

    /// The warning states the size that will actually be written, because
    /// "your max size is smaller" alone leaves the reader to do the
    /// arithmetic.
    func testTheWarningNamesTheSizeThatWillActuallyBeWritten() {
        let help = SessionBarState.capOverridesCropHelp(
            crop: pixels(1200, 800), maxDimension: 600
        )
        XCTAssertTrue(help.contains("600×400"), help)
        XCTAssertTrue(help.contains("1200×800"), help)
    }

    /// Empty when there is nothing to warn about, so the glyph that holds its
    /// space permanently does not show a tooltip for something invisible.
    func testTheWarningIsEmptyWhenTheCapDoesNotWin() {
        XCTAssertTrue(
            SessionBarState.capOverridesCropHelp(
                crop: pixels(1200, 1200), maxDimension: 2000
            ).isEmpty
        )
        XCTAssertTrue(
            SessionBarState.capOverridesCropHelp(crop: nil, maxDimension: 500).isEmpty
        )
    }

    // MARK: - Does the row fit

    /// The expanded panel has no narrow-width fallback — its rows fit at
    /// `ContentView`'s 340pt floor or they overflow it — and SwiftUI answers
    /// overflow by squeezing the children rather than by complaining. The
    /// first version of this row overflowed by 18pt and looked very nearly
    /// right on screen, which is why the fit is asserted here rather than
    /// eyeballed.
    func testTheCropRowFitsAtTheWindowsNarrowestWidth() {
        XCTAssertTrue(SessionBarState.cropRowFits(atWindowWidth: 340))
    }

    /// And the test has to be capable of failing: a row that fits at any width
    /// would pass the assertion above while telling us nothing.
    func testTheFitCheckActuallyRefusesAWindowTooNarrow() {
        XCTAssertFalse(SessionBarState.cropRowFits(atWindowWidth: 200))
    }

    /// Stated as a number so that changing any one width has to be a
    /// deliberate act rather than a quiet accumulation.
    func testTheCropRowsWidthIsWhatItsPartsAddUpTo() {
        // 106 capsule (9 + 36 + 4 + 8 + 4 + 36 + 9) + 8 + 88 mode control.
        XCTAssertEqual(SessionBarState.CropRow.capsuleWidth, 106)
        XCTAssertEqual(SessionBarState.CropRow.width, 202)
    }

    // MARK: - A crop with one number

    /// **The bar says so rather than saying nothing.** A crop needs both
    /// sides, so one number crops nothing — and staying silent about that
    /// reproduces the defect the live parse was built to prevent: a number
    /// sitting on screen as evidence that something should have happened, and
    /// a batch processed as though it had never been typed.
    func testTheSummarySaysWhenACropIsMissingASide() {
        let summary = SessionBarState.summary(
            format: nil, quality: nil, storedQuality: .standard,
            maxDimension: nil, crop: nil, cropIsHalfFilled: true
        )
        XCTAssertEqual(
            summary, "App default · Standard · No limit · Crop needs both sides"
        )
    }

    /// And says nothing once both are in, because then there is a crop to name.
    func testTheSummaryNamesTheCropOnceBothSidesAreIn() {
        let summary = SessionBarState.summary(
            format: nil, quality: nil, storedQuality: .standard,
            maxDimension: nil, crop: pixels(1200, 800), cropIsHalfFilled: false
        )
        XCTAssertEqual(summary, "App default · Standard · No limit · Crop 1200×800")
        XCTAssertFalse(summary.contains("needs"))
    }

    /// A real crop wins over the warning if both are somehow passed, because a
    /// crop that exists is the more useful thing to state.
    func testARealCropTakesPrecedenceOverTheWarning() {
        let summary = SessionBarState.summary(
            format: nil, quality: nil, storedQuality: .standard,
            maxDimension: nil, crop: ratio(1, 1), cropIsHalfFilled: true
        )
        XCTAssertTrue(summary.contains("Crop 1:1"))
        XCTAssertFalse(summary.contains("needs"))
    }

    /// Nothing typed at all is not a half-filled crop — it is the off state,
    /// and the bar stays quiet about it.
    func testAnEmptyCropSaysNothing() {
        XCTAssertFalse(CropField.isHalfFilled(width: "", height: ""))
        let summary = SessionBarState.summary(
            format: nil, quality: nil, storedQuality: .standard,
            maxDimension: nil, crop: nil, cropIsHalfFilled: false
        )
        XCTAssertFalse(summary.lowercased().contains("crop"))
    }
}
