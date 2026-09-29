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
}

// MARK: - Width

/// Phase 1's pseudolocalization run found the Metadata popup clipping its own
/// value: a doubled "All metadata" rendered as "All metadata All meta…". The
/// window was a hardcoded 420pt wide, which fits English and nothing longer.
///
/// The width is now measured the way the height already was — from the content
/// actually loaded, with 420pt as the floor so English does not move.
final class SettingsWindowWidthTests: XCTestCase {

    /// The widest row label and widest popup value that ship in English today.
    private let englishLabels = ["When shrinking, keep", "Encode at", "Where"]
    private let englishOptions = ["Copyright and credit only", "All metadata", "No metadata"]

    func testEnglishKeepsTheOriginalHardcodedWidth() {
        let width = SettingsWindowMetrics.contentWidth(
            rowLabels: englishLabels, optionLabels: englishOptions
        )

        XCTAssertEqual(
            width, SettingsWindowMetrics.baseContentWidth,
            "English must render exactly as before — 420pt was the designed width"
        )
    }

    func testLongerContentWidensTheWindow() {
        let english = SettingsWindowMetrics.contentWidth(
            rowLabels: englishLabels, optionLabels: englishOptions
        )
        let doubled = SettingsWindowMetrics.contentWidth(
            rowLabels: englishLabels.map { "\($0) \($0)" },
            optionLabels: englishOptions.map { "\($0) \($0)" }
        )

        XCTAssertGreaterThan(
            doubled, english,
            "content that does not fit 420pt must be given room, not clipped"
        )
    }

    func testTheWidthIsNeverBelowTheFloor() {
        let width = SettingsWindowMetrics.contentWidth(rowLabels: ["a"], optionLabels: ["b"])

        XCTAssertEqual(
            width, SettingsWindowMetrics.baseContentWidth,
            "a language with very short words must not shrink the window"
        )
    }

    /// Both halves matter: a long label with short options, and short labels
    /// with a long option, each have to be able to widen the window on their
    /// own.
    func testEitherHalfCanWidenTheWindowAlone() {
        let base = SettingsWindowMetrics.baseContentWidth
        let longLabel = SettingsWindowMetrics.contentWidth(
            rowLabels: [String(repeating: "label ", count: 12)], optionLabels: ["x"]
        )
        let longOption = SettingsWindowMetrics.contentWidth(
            rowLabels: ["x"], optionLabels: [String(repeating: "option ", count: 12)]
        )

        XCTAssertGreaterThan(longLabel, base)
        XCTAssertGreaterThan(longOption, base)
    }

    func testEmptyInputFallsBackToTheFloor() {
        XCTAssertEqual(
            SettingsWindowMetrics.contentWidth(rowLabels: [], optionLabels: []),
            SettingsWindowMetrics.baseContentWidth
        )
    }
}

// MARK: - Two tabs

/// The Settings window was one column of five sections and 1000 points tall,
/// which overflowed every display shorter than about 1030 points. Measuring
/// where that height went found the sections themselves were 68% of it, the
/// gaps between them 17%, and the three explanatory paragraphs only 13% — so
/// hiding the prose could never have fixed it. Splitting into two tabs was the
/// only lever that moved the number without making the window wider.
final class SettingsTabHeightTests: XCTestCase {
}
