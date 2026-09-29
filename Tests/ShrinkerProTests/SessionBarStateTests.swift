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

    // MARK: - When the crop supersedes the max size

    /// A pixel crop states the output size outright, so the max size has
    /// nothing left to cap and the field is switched off rather than
    /// overruled. Composing them meant "Crop 1200×1200, Max 500px" quietly
    /// writing 500×500 files — correct arithmetic, and a warning about two
    /// controls fighting, which is a sign one of them should not be there.
    func testAPixelCropSupersedesTheMaxSize() {
        XCTAssertTrue(SessionBarState.maxSizeIsSupersededByCrop(crop: pixels(1200, 1200)))
        XCTAssertTrue(SessionBarState.maxSizeIsSupersededByCrop(crop: pixels(40, 40)))
    }

    /// A ratio crop is the opposite case: it says nothing about size, so the
    /// cap is the only thing sizing the result and stays live.
    func testARatioCropLeavesTheMaxSizeAlone() {
        XCTAssertFalse(SessionBarState.maxSizeIsSupersededByCrop(crop: ratio(1, 1)))
        XCTAssertFalse(SessionBarState.maxSizeIsSupersededByCrop(crop: ratio(16, 9)))
    }

    /// And with no crop at all the field is live, obviously — but worth
    /// pinning, because keying this on the mode rather than on a finished
    /// crop would disable the one control that can resize anything the moment
    /// someone touched the mode switch.
    func testNoCropLeavesTheMaxSizeAlone() {
        XCTAssertFalse(SessionBarState.maxSizeIsSupersededByCrop(crop: nil))
    }

    /// The explanation names the size that will actually be written and both
    /// ways out, because "does not apply" alone leaves the reader stuck.
    func testTheExplanationNamesTheSizeAndTheWayOut() {
        let help = SessionBarState.maxSizeSupersededHelp(crop: pixels(1200, 800))
        XCTAssertTrue(help.contains("1200×800"), help)
        XCTAssertTrue(help.lowercased().contains("ratio"), help)
    }

    /// Pins the full sentence, not just its substrings, so a future split of
    /// this string around its interpolation — the mistake this text was
    /// rewritten to fix — is caught here rather than only by a translator.
    func testTheExplanationIsOneWholeSentence() {
        XCTAssertEqual(
            SessionBarState.maxSizeSupersededHelp(crop: pixels(1200, 800)),
            "The crop already sets the size — every image comes out 1200×800. Switch the crop to a ratio, or clear it, to use a max size."
        )
    }

    /// Empty while the field is live, so a dimmed-looking control never shows
    /// a tooltip explaining a state it is not in.
    func testTheExplanationIsEmptyWhileTheFieldIsLive() {
        XCTAssertTrue(SessionBarState.maxSizeSupersededHelp(crop: ratio(1, 1)).isEmpty)
        XCTAssertTrue(SessionBarState.maxSizeSupersededHelp(crop: nil).isEmpty)
    }

    /// Ratio leads the control and the enum, and is what a session starts on:
    /// it is the milder of the two, leaving every other control alone where a
    /// pixel size switches the max size off.
    func testRatioIsTheFirstModeOffered() {
        XCTAssertEqual(CropTarget.Mode.allCases, [.ratio, .pixels])
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

    /// `isHalfFilled` is what `AppModel.cropIsIncomplete` is built on, and
    /// therefore what blocks the panel and the drop. Nothing typed at all is
    /// not half filled — that is the off state — and neither is a full pair.
    func testHalfFilledIsExactlyOneSide() {
        XCTAssertTrue(CropField.isHalfFilled(width: "1200", height: ""))
        XCTAssertTrue(CropField.isHalfFilled(width: "", height: "800"))
        XCTAssertFalse(CropField.isHalfFilled(width: "", height: ""))
        XCTAssertFalse(CropField.isHalfFilled(width: "1200", height: "800"))
    }

    /// Zero is a field's off state, so it counts as empty on both sides of
    /// the question rather than as a number that happens to be unusable.
    func testZeroCountsAsEmptyForTheHalfFilledCheck() {
        XCTAssertTrue(CropField.isHalfFilled(width: "1200", height: "0"))
        XCTAssertFalse(CropField.isHalfFilled(width: "0", height: "0"))
    }

    /// The summary has no case for a half-typed crop and does not need one:
    /// the panel cannot be closed while one exists, so the bar is never
    /// collapsed in that state.
    func testTheSummaryHasNoHalfFilledCase() {
        let summary = SessionBarState.summary(
            format: nil, quality: nil, storedQuality: .standard,
            maxDimension: nil, crop: nil
        )
        XCTAssertFalse(summary.lowercased().contains("crop"))
    }
}

// MARK: - The max size field's width

/// Phase 1's pseudolocalization run found the max size field clipping its own
/// placeholder: a doubled "No limit" rendered as "No limit N". The field was a
/// hardcoded 112pt with `.byClipping`, which fits English and nothing longer —
/// German's "Keine Begrenzung" is twice the length.
///
/// The width is now measured from the placeholder actually loaded, with 112pt
/// as the floor so English does not move a pixel, and a cap so the field can
/// never push the row past the window's 340pt minimum.
final class MaxSizeFieldWidthTests: XCTestCase {

    func testEnglishKeepsTheOriginalHardcodedWidth() {
        let width = SessionBarState.maxSizeFieldWidth(placeholder: "No limit", unit: "px")

        XCTAssertEqual(
            width, 112,
            "English must render exactly as before — 112pt was the designed width"
        )
    }

    func testALongerPlaceholderWidensTheField() {
        let english = SessionBarState.maxSizeFieldWidth(placeholder: "No limit", unit: "px")
        let german = SessionBarState.maxSizeFieldWidth(placeholder: "Keine Begrenzung", unit: "px")

        XCTAssertGreaterThan(
            german, english,
            "a placeholder that does not fit 112pt must be given room, not clipped"
        )
    }

    func testTheFieldNeverOutgrowsTheNarrowestWindow() {
        let absurd = String(repeating: "Begrenzung ", count: 20)

        let width = SessionBarState.maxSizeFieldWidth(placeholder: absurd, unit: "px")

        XCTAssertLessThanOrEqual(
            width, SessionBarState.maxSizeFieldWidthCap,
            "past the cap the field must stop growing and let the text ellipsise"
        )
    }

    /// The cap is derived from the panel's own geometry, not guessed: whatever
    /// is left of a 340pt window after the gutters, the label column and the
    /// unit label.
    func testTheCapLeavesTheRowFittingAtMinimumWindowWidth() {
        let cap = SessionBarState.maxSizeFieldWidthCap
        let consumed = SessionBarState.panelGutters
            + SessionBarState.labelColumnWidth
            + SessionBarState.labelSpacing
            + cap

        XCTAssertLessThanOrEqual(consumed, 340, "the max size row must fit the narrowest window")
    }

    /// The unit label lives inside the field group, so a longer one consumes
    /// the group's own width rather than changing what the row may take.
    func testAWiderUnitLabelConsumesTheFieldsOwnWidth() {
        // Measured above the floor: with a short placeholder both clamp to
        // 112pt and the unit's contribution is invisible.
        let px = SessionBarState.maxSizeFieldWidth(placeholder: "Keine Begrenzung", unit: "px")
        let pixel = SessionBarState.maxSizeFieldWidth(placeholder: "Keine Begrenzung", unit: "Pixel")

        XCTAssertGreaterThan(px, SessionBarState.baseMaxSizeFieldWidth, "guard: must be above the floor")
        XCTAssertGreaterThan(
            pixel, px,
            "a wider unit pushes the group wider, since both sit inside the same frame"
        )
    }
}

// MARK: - The crop mode control's width

/// The third fixed-width control in the session panel, and the last to be
/// measured rather than assumed — the max size field and the Settings window
/// were both already doing this.
///
/// German found it. `ratio | px` draws at 82pt inside an 88pt frame, so
/// English was never clipped and the old comment claiming "anything narrower
/// clips ratio" was safe by accident; `Verhältnis | px` needs 115pt and would
/// have been cut. The first German draft answered that by choosing a shorter,
/// weaker word, which is a translation being bent around a layout constant —
/// and the same trade would have been made silently in each of the 34
/// languages still to come.
///
/// `@MainActor` because `modeWidth(labels:)` builds a real
/// `NSSegmentedControl` to measure, and AppKit views are main-actor isolated.
@MainActor
final class CropModeWidthTests: XCTestCase {

    func testEnglishKeepsTheOriginalHardcodedWidth() {
        let width = SessionBarState.CropRow.modeWidth(labels: ["ratio", "px"])

        XCTAssertEqual(
            width, SessionBarState.CropRow.baseModeWidth,
            "English draws under the floor, so it must land exactly on 88pt and not move"
        )
    }

    /// The assertion above would pass just as happily if the function ignored
    /// its labels and returned the floor. This is what separates a floor from
    /// a hardcoded number.
    func testALongerLabelWidensTheControl() {
        let english = SessionBarState.CropRow.modeWidth(labels: ["ratio", "px"])
        let german = SessionBarState.CropRow.modeWidth(labels: ["Verhältnis", "px"])

        XCTAssertGreaterThan(
            german, english,
            "a label that does not fit 88pt must be given room, not clipped"
        )
    }

    func testTheControlNeverOutgrowsItsCap() {
        let absurd = String(repeating: "Verhältnis ", count: 20)

        let width = SessionBarState.CropRow.modeWidth(labels: [absurd, "px"])

        XCTAssertLessThanOrEqual(
            width, SessionBarState.CropRow.modeWidthCap,
            "past the cap the control must stop growing and compress instead"
        )
    }

    /// English still fits the narrowest window the app allows, which is the
    /// property the row's arithmetic has always existed to protect.
    func testTheEnglishRowStillFitsTheNarrowestWindow() {
        let width = SessionBarState.CropRow.modeWidth(labels: ["ratio", "px"])

        XCTAssertTrue(
            SessionBarState.cropRowFits(
                atWindowWidth: SessionBarState.baseMinimumWindowWidth, modeWidth: width
            ),
            "English must be unchanged: the row fits 340pt exactly, as it always did"
        )
    }

    /// And German does not — recorded rather than glossed over. The designed
    /// row spends the whole 202pt a 340pt window leaves it, so any mode
    /// control above the floor needs a wider window. It fits the width the
    /// window actually opens at, which is what makes this a narrow-window
    /// question rather than a clipped control.
    func testAWiderLabelNeedsMoreThanTheNarrowestWindow() {
        let german = SessionBarState.CropRow.modeWidth(labels: ["Verhältnis", "px"])

        XCTAssertFalse(
            SessionBarState.cropRowFits(
                atWindowWidth: SessionBarState.baseMinimumWindowWidth, modeWidth: german
            ),
            "guard: if this ever fits the English floor, the cap or the floor has moved — this failing is what MinimumWindowWidthTests exists to answer"
        )
        XCTAssertTrue(
            SessionBarState.cropRowFits(
                atWindowWidth: SessionBarState.defaultWindowWidth, modeWidth: german
            ),
            "the row must fit the width the window actually opens at"
        )
    }

    /// The cap is derived from the panel's own geometry rather than guessed,
    /// and it has to come from the default window rather than the minimum
    /// one: at 340pt the arithmetic yields the floor itself, and a cap equal
    /// to its own floor is a control that can never grow.
    func testTheCapIsWhatTheDefaultWindowLeavesTheControl() {
        let cap = SessionBarState.CropRow.modeWidthCap
        let consumed = SessionBarState.panelGutters
            + SessionBarState.labelColumnWidth
            + SessionBarState.labelSpacing
            + SessionBarState.CropRow.capsuleWidth
            + SessionBarState.CropRow.spacing
            + cap

        XCTAssertEqual(consumed, SessionBarState.defaultWindowWidth)
        XCTAssertGreaterThan(
            cap, SessionBarState.CropRow.baseModeWidth,
            "a cap at or below the floor would leave the control unable to grow at all"
        )
    }

    /// Measured at the control size the call site actually uses. The same two
    /// labels at `.regular` come back 8pt wider, which would push every
    /// language — English included — past a floor it currently sits under.
    func testTheMeasurementUsesTheCallSitesControlSize() {
        let regular = NSSegmentedControl(
            labels: ["ratio", "px"], trackingMode: .selectOne, target: nil, action: nil
        )
        regular.sizeToFit()

        XCTAssertGreaterThan(
            regular.intrinsicContentSize.width, SessionBarState.CropRow.baseModeWidth,
            "guard: at .regular English would exceed the floor, which is the wrong measurement"
        )
        XCTAssertEqual(
            SessionBarState.CropRow.modeWidth(labels: ["ratio", "px"]),
            SessionBarState.CropRow.baseModeWidth,
            "at .small, the size the picker is actually drawn at, English stays on the floor"
        )
    }
}

// MARK: - The window's own minimum

/// At 340 points with the session panel open, German did not degrade — it
/// overflowed. The panel has a fixed intrinsic width, so the window clipped
/// it from the left and ate the label column: "SITZUNGSEINSTELLUNGEN" rendered
/// as "TZUNGSEINSTELLUNGEN", every row label lost its first characters.
///
/// `cropRowFits` already computed that this would happen and nothing consulted
/// it — arithmetic with no caller. These tests make the window's minimum a
/// derived number rather than a constant, so the floor is whatever the panel
/// actually needs in the language being displayed.
@MainActor
final class MinimumWindowWidthTests: XCTestCase {

    func testEnglishKeepsTheOriginalFloor() {
        let width = SessionBarState.minimumWindowWidth(modeLabels: ["ratio", "px"])

        XCTAssertEqual(
            width, SessionBarState.baseMinimumWindowWidth + SessionBarState.minimumComfortMargin,
            "English gets the designed floor plus the slack that stops the panel filling the window edge to edge"
        )
    }

    func testALanguageWithAWiderModeControlRaisesTheFloor() {
        let english = SessionBarState.minimumWindowWidth(modeLabels: ["ratio", "px"])
        let german = SessionBarState.minimumWindowWidth(modeLabels: ["Verhältnis", "px"])

        XCTAssertGreaterThan(
            german, english,
            "German's mode control needs 115pt against the 88pt floor; the window has to follow"
        )
    }

    /// The point of deriving it. Whatever the minimum comes out as, the crop
    /// row must actually fit inside it — otherwise the two calculations
    /// disagree and the overflow comes back in some language nobody measured.
    func testTheDerivedMinimumAlwaysFitsTheCropRow() {
        for labels in [["ratio", "px"], ["Verhältnis", "px"], ["коэффициент", "пкс"], ["比率", "px"]] {
            let minimum = SessionBarState.minimumWindowWidth(modeLabels: labels)
            let mode = SessionBarState.CropRow.modeWidth(labels: labels)

            XCTAssertTrue(
                SessionBarState.cropRowFits(atWindowWidth: minimum, modeWidth: mode),
                "the crop row does not fit the minimum derived for \(labels)"
            )
        }
    }

    func testTheFloorIsNeverLoweredBelowTheDesignedMinimum() {
        let tiny = SessionBarState.minimumWindowWidth(modeLabels: ["a", "b"])

        XCTAssertGreaterThanOrEqual(
            tiny, SessionBarState.baseMinimumWindowWidth + SessionBarState.minimumComfortMargin
        )
    }
}
