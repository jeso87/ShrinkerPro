import XCTest
@testable import ShrinkerPro

final class ReleaseNotesTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testParsesHeadingsWrappedBulletsAndParagraphs() {
        let text = """
        ### Meet Shrinker Studio

        Shrinker Pro stays free and unlimited. Studio is an optional upgrade inside
        it.

        - **Compare before you save:** split, side by side, or a Difference view that
          shows every pixel compression changed.
        - **Recipes:** save it for any batch.
        """
        XCTAssertEqual(ReleaseNotes.parse(text), [
            .heading("Meet Shrinker Studio"),
            .paragraph("Shrinker Pro stays free and unlimited. Studio is an optional upgrade inside it."),
            .bullet("**Compare before you save:** split, side by side, or a Difference view that shows every pixel compression changed."),
            .bullet("**Recipes:** save it for any batch."),
        ])
    }

    func testNewestFirstUpToTheRunningVersionAndNumericOrder() throws {
        for v in ["1.9.0", "1.10.0", "1.8.0", "2.0.0"] { try write("\(v).md", "- \(v)") }
        try write("1.10.0.fr.md", "- fr")
        let notes = ReleaseNotes.load(from: directory, current: "1.10.0", language: "en", limit: 5)
        XCTAssertEqual(notes.map(\.version), ["1.10.0", "1.9.0", "1.8.0"], "2.0.0 is newer than the app; 1.10 sorts above 1.9")
    }

    func testKeepsTheNewestFive() throws {
        for minor in 0..<8 { try write("1.\(minor).0.md", "- note") }
        let notes = ReleaseNotes.load(from: directory, current: "1.7.0", language: "en")
        XCTAssertEqual(notes.map(\.version), ["1.7.0", "1.6.0", "1.5.0", "1.4.0", "1.3.0"])
    }

    func testPicksTheTranslationThenFallsBackToEnglish() throws {
        try write("1.8.0.md", "- English")
        try write("1.8.0.pt-BR.md", "- Brasil")
        try write("1.8.0.fr.md", "- Français")
        try write("1.4.0.md", "- Old, English only")
        XCTAssertEqual(ReleaseNotes.load(from: directory, current: "1.8.0", language: "pt-BR").map(\.blocks),
                       [[.bullet("Brasil")], [.bullet("Old, English only")]])
        XCTAssertEqual(ReleaseNotes.load(from: directory, current: "1.8.0", language: "fr-CA").first?.blocks,
                       [.bullet("Français")], "a regional variant falls back to its base language")
        XCTAssertEqual(ReleaseNotes.load(from: directory, current: "1.8.0", language: "en").first?.blocks,
                       [.bullet("English")])
    }

    func testOnlyEnglishFilesNameAVersion() {
        XCTAssertEqual(ReleaseNotes.englishVersion(ofFileNamed: "1.7.0.md"), "1.7.0")
        XCTAssertNil(ReleaseNotes.englishVersion(ofFileNamed: "1.7.0.fr.md"))
        XCTAssertNil(ReleaseNotes.englishVersion(ofFileNamed: "1.7.0.zh-Hant.md"))
        XCTAssertNil(ReleaseNotes.englishVersion(ofFileNamed: "README.md"))
    }

    /// The real notes ship inside the app, and the running version has some.
    func testTheAppBundlesItsOwnNotes() throws {
        let folder = try XCTUnwrap(Bundle(for: AppModel.self).url(forResource: "release-notes", withExtension: nil)
            ?? Bundle.main.url(forResource: "release-notes", withExtension: nil))
        let version = try XCTUnwrap(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        let notes = ReleaseNotes.load(from: folder, current: version, language: "en")
        XCTAssertEqual(notes.first?.version, version)
        XCTAssertFalse(notes.first?.blocks.isEmpty ?? true)
    }
}
