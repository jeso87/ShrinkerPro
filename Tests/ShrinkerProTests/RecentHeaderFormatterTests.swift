import XCTest
@testable import ShrinkerPro

/// Pure logic tests for `RecentHeaderFormatter` — pluralisation of the file
/// count and the negative-aggregate wording for the "Recent" header's
/// trailing text. No SwiftUI involved, so these can actually fail if the
/// logic regresses (unlike a view-body "test" that only ever renders green).
final class RecentHeaderFormatterTests: XCTestCase {

    private func expectedMagnitude(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    // MARK: - fileCountLabel

    func testFileCountLabelIsSingularForOne() {
        XCTAssertEqual(RecentHeaderFormatter.fileCountLabel(1), "1 file")
    }

    func testFileCountLabelIsPluralForZeroAndMultiple() {
        XCTAssertEqual(RecentHeaderFormatter.fileCountLabel(0), "0 files")
        XCTAssertEqual(RecentHeaderFormatter.fileCountLabel(2), "2 files")
        XCTAssertEqual(RecentHeaderFormatter.fileCountLabel(6), "6 files")
    }

    // MARK: - aggregateParts

    func testAggregatePartsForPositiveSavingsEndsWithSaved() {
        var session = SessionSummary()
        session.record(originalBytes: 5_000_000, shrunkBytes: 1_000_000)

        let parts = RecentHeaderFormatter.aggregateParts(for: session)

        XCTAssertEqual(parts.prefix, "1 file · ")
        XCTAssertEqual(parts.size, expectedMagnitude(4_000_000))
        XCTAssertEqual(parts.suffix, " saved")
    }

    func testAggregatePartsPluralisesMultipleFiles() {
        var session = SessionSummary()
        session.record(originalBytes: 3_000_000, shrunkBytes: 1_000_000)
        session.record(originalBytes: 2_000_000, shrunkBytes: 500_000)

        let parts = RecentHeaderFormatter.aggregateParts(for: session)

        XCTAssertEqual(parts.prefix, "2 files · ")
    }

    /// `SessionSummary.bytesSaved` can be negative when outputs grew overall
    /// (summed honestly, not clamped — see `SessionSummary.record`).
    /// `"−1.2 MB saved"` would read as nonsense, so a net-growth session
    /// must format the *magnitude* (no leading minus sign) and switch the
    /// trailing word to "larger" instead.
    func testAggregatePartsForNegativeSavingsReportsLargerWithPositiveMagnitude() {
        var session = SessionSummary()
        session.record(originalBytes: 100, shrunkBytes: 1_300_100) // grew by 1.3 MB-ish

        let parts = RecentHeaderFormatter.aggregateParts(for: session)

        XCTAssertEqual(session.bytesSaved, -1_300_000)
        XCTAssertEqual(parts.size, expectedMagnitude(1_300_000), "must format the magnitude, not the signed value")
        XCTAssertFalse(parts.size.contains("-"), "must never show a bare minus sign paired with \"larger\" or \"saved\"")
        XCTAssertEqual(parts.suffix, " larger")
    }

    func testAggregatePartsForZeroSavingsReadsAsSaved() {
        var session = SessionSummary()
        session.record(originalBytes: 1_000, shrunkBytes: 1_000)

        let parts = RecentHeaderFormatter.aggregateParts(for: session)

        XCTAssertEqual(parts.suffix, " saved", "a wash (net zero) is not a regression, so it should not read as \"larger\"")
    }
}
