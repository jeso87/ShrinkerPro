import XCTest
@testable import ShrinkerPro

/// Covers the conversion-rule rows in `SettingsView` — specifically that
/// the HEIC/HEIF row's picker genuinely cannot offer "Keep", unlike the
/// other four rows.
///
/// `SettingsView`'s two row types (`ConversionRuleRow` and
/// `HEICConversionRuleRow`, both `private`) render their `Picker` content
/// with `ForEach(<Type>.allCases, id: \.self)` — see SettingsView.swift —
/// so each row's option set *is* whichever `enum`'s `allCases` it iterates.
/// That makes the enums themselves the right, and only meaningful, level to
/// test: there is no separate "list of options" data structure that could
/// drift from what's rendered, and no SwiftUI view-tree inspection
/// dependency (e.g. ViewInspector) exists in this project to assert against
/// the rendered `Picker` any more directly than that.
final class SettingsViewTests: XCTestCase {

    /// The HEIC row's entire option set. No `.keep` case exists on this
    /// type at all — this isn't "the row doesn't show Keep today", it's
    /// "there is no Keep to show, ever, for any row built against this
    /// type". `Settings.heicConversion` and `ConversionRules.heic` are both
    /// typed `ConversionFormat`, so this is exactly what the live HEIC
    /// picker binds to and iterates.
    func testHEICPickerOffersExactlyThreeOptionsNoKeep() {
        XCTAssertEqual(ConversionFormat.allCases, [.jpeg, .webp, .avif])
        XCTAssertEqual(ConversionFormat.allCases.count, 3)
        XCTAssertFalse(
            ConversionFormat.allCases.map(\.rawValue).contains("keep"),
            "HEIC's picker must not offer a \"keep\" option"
        )
    }

    /// Contrast case: PNG/JPEG/WebP/AVIF rows are untouched by Change 1 —
    /// still four options, `.keep` included — proving the removal is
    /// specific to HEIC, not an accidental narrowing of every row.
    func testOtherFourRowsStillOfferFourOptionsIncludingKeep() {
        XCTAssertEqual(ConversionTarget.allCases, [.keep, .jpeg, .webp, .avif])
        XCTAssertEqual(ConversionTarget.allCases.count, 4)
    }
}
