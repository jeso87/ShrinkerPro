import XCTest
import CoreGraphics
@testable import ShrinkerPro

/// Covers the bound that stops the Settings window growing taller than the
/// screen it is being shown on.
///
/// The defect this replaces was `.fixedSize(horizontal: false, vertical: true)`
/// on `SettingsView`'s `Form`: a grouped `Form` on macOS is already a
/// scrollable list, and `fixedSize` pinned it to its full intrinsic height, so
/// it never compressed and never scrolled. On a short display the bottom of
/// the window simply went off the screen and could not be reached.
///
/// The replacement is a *measured* bound rather than a constant, because the
/// bug was a window too tall for a screen nobody measured — and a hard-coded
/// maximum would be the same mistake wearing a different number. That makes
/// the arithmetic worth testing directly: it is the whole fix, and it is the
/// one part of it that can be checked without a running window server.
///
/// Lives here rather than inside a `body` for the reason `MaxSizeField`,
/// `SessionBarState`, `OutputNaming` and `OutputWarning` all do: logic left
/// inline in a view is logic no test in this project can reach.
final class SettingsWindowMetricsTests: XCTestCase {

    /// A desktop display tall enough to show the whole window. The bound is
    /// simply the visible height less the title bar and a margin, and nothing
    /// is clamped.
    func testADesktopDisplayGetsTheVisibleHeightLessChrome() {
        XCTAssertEqual(
            SettingsWindowMetrics.maxContentHeight(forVisibleHeight: 1050), 990
        )
    }

    /// A 13" laptop, which is the machine the bug was reported from. The five
    /// sections come to about 1000 points, so this is the case that must
    /// clamp — and clamping is what makes the window scroll instead of running
    /// off the bottom of the screen.
    ///
    /// Asserted as an inequality against the content height rather than only
    /// as a number, because the number on its own would still pass if the
    /// window were one point short of useless.
    func testALaptopDisplayIsClampedSoTheWindowScrolls() {
        let bound = SettingsWindowMetrics.maxContentHeight(forVisibleHeight: 800)
        XCTAssertEqual(bound, 740)
        XCTAssertLessThan(bound, 1000, "the settings content must be clamped on a laptop")
        XCTAssertGreaterThan(bound, 600, "clamped is not the same as cramped")
    }

    /// An absurdly short display — a sliver of a screen, or a reading taken
    /// while a display is being reconfigured. The floor stops the window
    /// collapsing to something unusable; the `Form` scrolls instead.
    ///
    /// 360 rather than a rounder number because the floor only bites once the
    /// visible height drops within `chromeAllowance` of it. Picking the
    /// example off the two constants keeps this honest if either moves.
    func testAnAbsurdlyShortDisplayIsHeldAtTheFloor() {
        let justInsideTheFloor =
            SettingsWindowMetrics.minimumContentHeight + SettingsWindowMetrics.chromeAllowance - 20
        XCTAssertEqual(
            SettingsWindowMetrics.maxContentHeight(forVisibleHeight: justInsideTheFloor),
            SettingsWindowMetrics.minimumContentHeight
        )
    }

    /// The floor must never win *past* the screen: on a display shorter than
    /// the floor itself, a 320pt bound would put us straight back in the bug
    /// being fixed. Clamping to the visible height is what keeps the window
    /// reachable at every size, which is the property that actually matters.
    func testTheFloorNeverExceedsTheScreenItself() {
        for visible in stride(from: CGFloat(100), through: 2000, by: 10) {
            let bound = SettingsWindowMetrics.maxContentHeight(forVisibleHeight: visible)
            XCTAssertLessThanOrEqual(
                bound, visible,
                "a \(visible)pt screen was handed a \(bound)pt window"
            )
            XCTAssertGreaterThan(bound, 0, "a \(visible)pt screen was handed no height at all")
        }
    }

    /// A nonsense reading — `NSScreen` momentarily reporting nothing — must
    /// produce a usable window rather than a zero-height one. Falling back to
    /// the floor is the same answer as "too short to matter".
    func testANonsenseReadingFallsBackToTheFloor() {
        XCTAssertEqual(
            SettingsWindowMetrics.maxContentHeight(forVisibleHeight: 0),
            SettingsWindowMetrics.minimumContentHeight
        )
        XCTAssertEqual(
            SettingsWindowMetrics.maxContentHeight(forVisibleHeight: -500),
            SettingsWindowMetrics.minimumContentHeight
        )
    }

    /// Taller screens never yield shorter windows. Stated as a property
    /// rather than a case because it is the thing a future tweak to the
    /// allowance would most plausibly break.
    func testTheBoundNeverShrinksAsTheScreenGrows() {
        var previous = SettingsWindowMetrics.maxContentHeight(forVisibleHeight: 1)
        for visible in stride(from: CGFloat(1), through: 3000, by: 7) {
            let bound = SettingsWindowMetrics.maxContentHeight(forVisibleHeight: visible)
            XCTAssertGreaterThanOrEqual(bound, previous, "went backwards at \(visible)pt")
            previous = bound
        }
    }

    // MARK: - Whether the window has to scroll

    /// The fade and chevron at the bottom of the window appear only where
    /// something is genuinely hidden. On a display tall enough to show all
    /// 1000 points of settings, an affordance promising more below would be
    /// pointing at nothing.
    func testATallDisplayShowsNoScrollAffordance() {
        XCTAssertFalse(
            SettingsWindowMetrics.contentScrolls(contentHeight: 1000, visibleHeight: 1600)
        )
    }

    /// The reported case: a laptop, where the settings do not fit and the user
    /// needs to be told there is more.
    func testALaptopDisplayShowsTheScrollAffordance() {
        XCTAssertTrue(
            SettingsWindowMetrics.contentScrolls(contentHeight: 1000, visibleHeight: 800)
        )
    }

    /// A display that clamps by only a few points draws nothing. This is the
    /// case that was observed for real: 1050 points of usable height gives a
    /// 990 point bound against roughly 1000 points of content, so ten points
    /// are technically hidden and the pane looks complete. A fade and a
    /// chevron over that is an affordance pointing at nothing.
    func testADisplayThatBarelyClampsShowsNoAffordance() {
        XCTAssertLessThan(
            SettingsWindowMetrics.maxContentHeight(forVisibleHeight: 1050), 1000,
            "this case is only interesting if it does clamp"
        )
        XCTAssertFalse(
            SettingsWindowMetrics.contentScrolls(contentHeight: 1000, visibleHeight: 1050)
        )
    }

    /// The affordance never appears without a clamp behind it. The converse is
    /// deliberately not true — see `scrollAffordanceThreshold` — so this is
    /// asserted one way only, which is the direction that matters: the fade
    /// must never promise content that is not there.
    func testTheAffordanceNeverAppearsWithoutAClamp() {
        let content: CGFloat = 1000
        for visible in stride(from: CGFloat(200), through: 2400, by: 10) {
            guard SettingsWindowMetrics.contentScrolls(
                contentHeight: content, visibleHeight: visible
            ) else { continue }
            XCTAssertLessThan(
                SettingsWindowMetrics.maxContentHeight(forVisibleHeight: visible), content,
                "the affordance appeared at \(visible)pt with nothing hidden"
            )
        }
    }
}
