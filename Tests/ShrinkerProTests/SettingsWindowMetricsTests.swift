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

    /// A desktop display. Plenty of room, so the bound is simply the visible
    /// height less the allowance for the tab toolbar and the window frame —
    /// no clamping involved.
    func testADesktopDisplayGetsTheVisibleHeightLessChrome() {
        XCTAssertEqual(
            SettingsWindowMetrics.maxContentHeight(forVisibleHeight: 1050), 930
        )
    }

    /// A 13" laptop, which is the machine the bug was reported from. The
    /// tallest tab is about 430pt, so 680 leaves it unclamped — the tabs do
    /// the work here and the bound is only a backstop.
    func testALaptopDisplayLeavesTheTallestTabUnclamped() {
        let bound = SettingsWindowMetrics.maxContentHeight(forVisibleHeight: 800)
        XCTAssertEqual(bound, 680)
        XCTAssertGreaterThan(bound, 430, "the Images tab must not be clamped on a laptop")
    }

    /// An absurdly short display — a sliver of a screen, or a reading taken
    /// while a display is being reconfigured. The floor stops the window
    /// collapsing to something unusable; the `Form` scrolls instead.
    func testAnAbsurdlyShortDisplayIsHeldAtTheFloor() {
        XCTAssertEqual(
            SettingsWindowMetrics.maxContentHeight(forVisibleHeight: 400),
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
}
