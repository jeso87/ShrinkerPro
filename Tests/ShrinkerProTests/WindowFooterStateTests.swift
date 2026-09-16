import XCTest
@testable import ShrinkerPro

/// The footer's conditional behaviour, factored out of `WindowFooterView`
/// for the same reason `RecentHeaderFormatter` was factored out of
/// `RecentHeaderView`: this project has no view-tree testing dependency, so
/// logic left inline in a `body` is logic nothing can assert on.
///
/// It earns the separation — the growth warning is the one piece of the
/// footer that is genuinely conditional, and driving a SwiftUI menu through
/// the accessibility API to observe it proved unreliable.
final class WindowFooterStateTests: XCTestCase {

    func testGrowthWarningShowsOnlyForPNG() {
        XCTAssertTrue(WindowFooterState.showsGrowthWarning(for: .png))

        for format in [SessionFormat.jpeg, .webp, .avif] {
            XCTAssertFalse(
                WindowFooterState.showsGrowthWarning(for: format),
                "\(format.displayName) is lossy — it has no growth to warn about"
            )
        }
    }

    /// No override means no warning: with the footer showing "App default"
    /// there is nothing surprising in play to explain.
    func testGrowthWarningIsHiddenWithNoOverride() {
        XCTAssertFalse(WindowFooterState.showsGrowthWarning(for: nil))
    }

    /// Guards the reason this is a warning at all. If a second lossless
    /// target is ever added to `SessionFormat`, it will need its own growth
    /// warning, and this fails until someone decides that deliberately.
    func testExactlyOneFormatWarnsAboutGrowth() {
        let warning = SessionFormat.allCases.filter { WindowFooterState.showsGrowthWarning(for: $0) }
        XCTAssertEqual(
            warning, [.png],
            "a newly-added lossless conversion target needs its own growth warning"
        )
    }

    /// The glyph holds its space permanently so neither the footer's height
    /// nor its width shifts when the override changes — which means that
    /// while it is invisible it is still a hover target. Empty help text is
    /// what stops it showing a tooltip for a glyph nobody can see.
    func testHelpTextIsEmptyWhileTheWarningIsInvisible() {
        XCTAssertTrue(WindowFooterState.growthWarningHelp(for: nil).isEmpty)
        XCTAssertTrue(WindowFooterState.growthWarningHelp(for: .jpeg).isEmpty)
        XCTAssertFalse(WindowFooterState.growthWarningHelp(for: .png).isEmpty)
    }

    /// Drives the label's emphasis — semibold and accent-coloured while an
    /// override is in force, so the footer reads as "something is on" at a
    /// glance rather than only on inspection.
    func testOverrideCountsAsActiveOnlyWhenAFormatIsChosen() {
        XCTAssertFalse(WindowFooterState.isOverrideActive(nil))
        for format in SessionFormat.allCases {
            XCTAssertTrue(WindowFooterState.isOverrideActive(format), format.displayName)
        }
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

    /// The label's emphasis follows the same rule the value does, so the
    /// footer cannot show a setting as active while the engine treats it as
    /// off.
    func testTheLabelIsEmphasisedExactlyWhenTheCapApplies() {
        XCTAssertTrue(WindowFooterState.isMaxSizeActive("2000"))
        XCTAssertFalse(WindowFooterState.isMaxSizeActive(""))
        XCTAssertFalse(WindowFooterState.isMaxSizeActive("0"))
    }
}
