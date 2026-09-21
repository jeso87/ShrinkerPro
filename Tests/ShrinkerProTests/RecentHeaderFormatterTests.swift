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

    // MARK: - aggregate
    //
    // `fileCountLabel` used to be a separate function with its own tests,
    // resolving the plural `"3 files"` on its own so `aggregate` could
    // interpolate the finished fragment. That defeated the plural
    // mechanism (see the spec's "Plural forms"): the count is now part of
    // the aggregate's own catalog entry, so the singular and plural forms
    // are asserted here, through the sentence that actually ships.

    /// The old `aggregateParts` returned (prefix, size, suffix) so the view
    /// could colour the middle run. That shape put " saved" permanently
    /// after the number, which is English's word order and not everyone's.
    /// The replacement returns one localized sentence with the size run
    /// attributed, so a language may put the words in any order.

    func testAggregateReadsAsSavedForPositiveSavings() {
        var session = SessionSummary()
        session.record(originalBytes: 5_000_000, shrunkBytes: 1_000_000)

        let text = String(RecentHeaderFormatter.aggregate(for: session).characters)

        XCTAssertEqual(text, "1 file · \(expectedMagnitude(4_000_000)) saved")
    }

    /// Zero is the `other` category in English, not a category of its own.
    func testAggregatePluralisesZeroFiles() {
        let session = SessionSummary()

        let text = String(RecentHeaderFormatter.aggregate(for: session).characters)

        XCTAssertTrue(text.hasPrefix("0 files · "), text)
    }

    func testAggregatePluralisesMultipleFiles() {
        var session = SessionSummary()
        session.record(originalBytes: 3_000_000, shrunkBytes: 1_000_000)
        session.record(originalBytes: 2_000_000, shrunkBytes: 500_000)

        let text = String(RecentHeaderFormatter.aggregate(for: session).characters)

        XCTAssertTrue(text.hasPrefix("2 files · "), text)
    }

    /// A net-growth session must format the magnitude and swap the word, so
    /// it never reads "you saved -1.2 MB".
    func testAggregateForNegativeSavingsReportsLargerWithPositiveMagnitude() {
        var session = SessionSummary()
        session.record(originalBytes: 100, shrunkBytes: 1_300_100)

        let text = String(RecentHeaderFormatter.aggregate(for: session).characters)

        XCTAssertEqual(session.bytesSaved, -1_300_000)
        XCTAssertEqual(text, "1 file · \(expectedMagnitude(1_300_000)) larger")
        XCTAssertFalse(text.contains("-"), "must never show a bare minus sign")
    }

    func testAggregateForZeroSavingsReadsAsSaved() {
        var session = SessionSummary()
        session.record(originalBytes: 1_000, shrunkBytes: 1_000)

        let text = String(RecentHeaderFormatter.aggregate(for: session).characters)

        XCTAssertTrue(text.hasSuffix(" saved"), "a wash is not a regression")
    }

    /// The size run — and only the size run — is accented, whatever order
    /// the language puts the words in.
    func testOnlyTheSizeRunIsAccented() {
        var session = SessionSummary()
        session.record(originalBytes: 5_000_000, shrunkBytes: 1_000_000)

        let attributed = RecentHeaderFormatter.aggregate(for: session)
        let accented = attributed.runs
            .filter { $0.foregroundColor == Theme.savingsAccent }
            .map { String(attributed[$0.range].characters) }

        XCTAssertEqual(accented, [expectedMagnitude(4_000_000)])
    }
}
