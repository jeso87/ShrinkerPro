import XCTest
@testable import ShrinkerPro

/// UpdateChecker.compare is pure and is the testable core of Task 13 — no
/// network call is exercised here. The only check() coverage is the
/// unconfigured-repository short-circuit, which also makes no request; a
/// real GitHub API call would be slow, flaky offline/in CI, and is
/// deliberately out of scope per the task brief.
final class UpdateCheckerTests: XCTestCase {

    // MARK: - compare: newer versions

    func testDetectsPatchBump() {
        XCTAssertTrue(UpdateChecker.compare(current: "1.0.0", latestTag: "v1.0.1"))
    }

    func testDetectsMinorBump() {
        XCTAssertTrue(UpdateChecker.compare(current: "1.0.0", latestTag: "1.1.0"))
    }

    func testDetectsDoubleDigitMinorNumerically() {
        XCTAssertTrue(
            UpdateChecker.compare(current: "1.9.0", latestTag: "v1.10.0"),
            "1.10.0 is newer than 1.9.0 — must not compare as strings"
        )
    }

    func testDetectsNewerVersionWithFewerComponents() {
        XCTAssertTrue(UpdateChecker.compare(current: "1.0.0", latestTag: "v2.0"))
    }

    // MARK: - compare: same or older versions

    func testSameVersionIsNotAnUpdate() {
        XCTAssertFalse(UpdateChecker.compare(current: "1.0.0", latestTag: "v1.0.0"))
    }

    func testOlderPatchIsNotAnUpdate() {
        XCTAssertFalse(UpdateChecker.compare(current: "1.2.0", latestTag: "v1.1.9"))
    }

    func testOlderMajorIsNotAnUpdate() {
        XCTAssertFalse(UpdateChecker.compare(current: "2.0.0", latestTag: "v1.99.99"))
    }

    // MARK: - compare: malformed input

    func testNonNumericTagIsNotAnUpdate() {
        XCTAssertFalse(UpdateChecker.compare(current: "1.0.0", latestTag: "nightly"))
    }

    func testEmptyTagIsNotAnUpdate() {
        XCTAssertFalse(UpdateChecker.compare(current: "1.0.0", latestTag: ""))
    }

    // MARK: - check(): unconfigured repository, no network

    func testUnconfiguredRepositoryReportsNotConfiguredWithNilRepository() async {
        let status = await UpdateChecker(repository: nil).check()
        XCTAssertEqual(status, .notConfigured)
    }

    func testEmptyRepositoryStringReportsNotConfigured() async {
        // Mirrors the shipped Info.plist: SPRepository is present but "".
        let status = await UpdateChecker(repository: "").check()
        XCTAssertEqual(status, .notConfigured)
    }

    func testWhitespaceOnlyRepositoryReportsNotConfigured() async {
        let status = await UpdateChecker(repository: "   ").check()
        XCTAssertEqual(status, .notConfigured)
    }

    // MARK: - parseRelease: pure JSON parsing, no network

    func testParseReleaseExtractsTagAndURL() {
        let json = """
        {"tag_name": "v1.2.0", "html_url": "https://example.com/releases/tag/v1.2.0"}
        """.data(using: .utf8)!

        let parsed = UpdateChecker.parseRelease(data: json)
        XCTAssertEqual(parsed?.tag, "v1.2.0")
        XCTAssertEqual(parsed?.htmlURL, URL(string: "https://example.com/releases/tag/v1.2.0"))
    }

    func testParseReleaseToleratesMissingHTMLURL() {
        let json = #"{"tag_name": "v1.2.0"}"#.data(using: .utf8)!

        let parsed = UpdateChecker.parseRelease(data: json)
        XCTAssertEqual(parsed?.tag, "v1.2.0")
        XCTAssertNil(parsed?.htmlURL)
    }

    func testParseReleaseReturnsNilForMalformedJSON() {
        let garbage = "not json at all".data(using: .utf8)!
        XCTAssertNil(UpdateChecker.parseRelease(data: garbage))
    }

    func testParseReleaseReturnsNilWhenTagNameMissing() {
        let json = #"{"html_url": "https://example.com"}"#.data(using: .utf8)!
        XCTAssertNil(UpdateChecker.parseRelease(data: json))
    }
}
