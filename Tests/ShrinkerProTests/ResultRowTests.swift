import XCTest
@testable import ShrinkerPro

/// Pure logic tests for the byte-count/formatting additions to `ResultRow`
/// and the `SessionSummary` aggregate — no engine, no filesystem, no
/// `@MainActor` needed since neither type is actor-isolated.
final class ResultRowTests: XCTestCase {

    /// Builds the exact string the production formatter would produce, so
    /// assertions verify against real `ByteCountFormatter` output rather
    /// than a hand-typed guess that could silently drift from whatever the
    /// OS actually renders (e.g. locale/unit-suffix changes across macOS
    /// versions).
    private func expectedFileCountString(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    // MARK: - ResultRow.sizeSummary

    func testSizeSummaryJoinsBothSidesWithArrow() {
        let row = ResultRow(output: URL(fileURLWithPath: "/tmp/x.png"), originalBytes: 3_100_000, shrunkBytes: 1_200_000, savedPercent: 61)

        let expected = "\(expectedFileCountString(3_100_000)) → \(expectedFileCountString(1_200_000))"
        XCTAssertEqual(row.sizeSummary, expected)
    }

    func testSizeSummaryHandlesZeroShrunkBytes() {
        // Not a realistic ShrinkEngine output (it guards against writing an
        // empty file), but sizeSummary itself must not crash or misformat
        // on the boundary value.
        let row = ResultRow(output: URL(fileURLWithPath: "/tmp/x.png"), originalBytes: 1_000, shrunkBytes: 0, savedPercent: 100)

        let expected = "\(expectedFileCountString(1_000)) → \(expectedFileCountString(0))"
        XCTAssertEqual(row.sizeSummary, expected)
    }

    // MARK: - SessionSummary arithmetic

    func testRecordAccumulatesFileCountAndBytesSaved() {
        var session = SessionSummary()
        XCTAssertEqual(session.fileCount, 0)
        XCTAssertEqual(session.bytesSaved, 0)

        session.record(originalBytes: 1_000, shrunkBytes: 400)
        XCTAssertEqual(session.fileCount, 1)
        XCTAssertEqual(session.bytesSaved, 600)

        session.record(originalBytes: 2_000, shrunkBytes: 500)
        XCTAssertEqual(session.fileCount, 2)
        XCTAssertEqual(session.bytesSaved, 600 + 1_500, "bytesSaved must accumulate across records, not overwrite")
    }

    func testRecordAllowsNegativeBytesSavedWhenFileGrows() {
        // Mirrors ResultsListView's row-level handling of a negative
        // savedPercent: a file that grew is summed honestly, not clamped
        // to zero (which would hide the regression from the aggregate).
        var session = SessionSummary()
        session.record(originalBytes: 100, shrunkBytes: 150)

        XCTAssertEqual(session.fileCount, 1)
        XCTAssertEqual(session.bytesSaved, -50)
    }

    func testBytesSavedFormattedMatchesByteCountFormatterOutput() {
        var session = SessionSummary()
        session.record(originalBytes: 5_000_000, shrunkBytes: 1_000_000)

        XCTAssertEqual(session.bytesSavedFormatted, expectedFileCountString(4_000_000))
    }
}
