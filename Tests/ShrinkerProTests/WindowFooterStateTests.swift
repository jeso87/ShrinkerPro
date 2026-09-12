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
