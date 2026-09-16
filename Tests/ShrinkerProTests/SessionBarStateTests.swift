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
                format: nil, quality: nil, storedQuality: .standard, maxDimension: nil
            )
        )
    }

    func testAnyOneSettingMakesItModified() {
        XCTAssertTrue(
            SessionBarState.isModified(
                format: .webp, quality: nil, storedQuality: .standard, maxDimension: nil
            ),
            "a format override"
        )
        XCTAssertTrue(
            SessionBarState.isModified(
                format: nil, quality: .high, storedQuality: .standard, maxDimension: nil
            ),
            "a quality that differs from the stored default"
        )
        XCTAssertTrue(
            SessionBarState.isModified(
                format: nil, quality: nil, storedQuality: .standard, maxDimension: 2000
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
                format: nil, quality: .high, storedQuality: .high, maxDimension: nil
            )
        )
        XCTAssertTrue(
            SessionBarState.isModified(
                format: nil, quality: .standard, storedQuality: .high, maxDimension: nil
            ),
            "choosing Standard when the stored default is High IS an override"
        )
    }

    // MARK: - The summary line

    func testTheDefaultSummaryNamesTheDefaults() {
        XCTAssertEqual(
            SessionBarState.summary(
                format: nil, quality: nil, storedQuality: .standard, maxDimension: nil
            ),
            "App default · Standard · No limit"
        )
    }

    func testTheSummaryStatesEverySessionValue() {
        XCTAssertEqual(
            SessionBarState.summary(
                format: .webp, quality: .high, storedQuality: .standard, maxDimension: 2000
            ),
            "WebP · High · Max 2000px"
        )
    }

    /// The summary shows what will actually happen, so an untouched quality
    /// reads as the stored default rather than as a fixed "Standard".
    func testAnUntouchedQualityShowsTheStoredDefault() {
        XCTAssertEqual(
            SessionBarState.summary(
                format: nil, quality: nil, storedQuality: .superLow, maxDimension: nil
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
                    format: nil, quality: level, storedQuality: .standard, maxDimension: nil
                )
                .contains(level.displayName),
                "\(level) is missing from its own summary"
            )
        }
    }

    // MARK: - Narrow windows

    /// The bar must never wrap. Below the threshold it drops the parts that
    /// repeat what the dot and the summary already say.
    func testInlineDetailsAreDroppedOnANarrowBar() {
        XCTAssertTrue(SessionBarState.showsInlineDetails(atWidth: 500))
        XCTAssertTrue(SessionBarState.showsInlineDetails(atWidth: 380))
        XCTAssertFalse(SessionBarState.showsInlineDetails(atWidth: 379))
        XCTAssertFalse(SessionBarState.showsInlineDetails(atWidth: 320))
    }
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
