import XCTest
@testable import ShrinkerPro

@MainActor
final class AppModelTests: XCTestCase {

    /// A missing bundled resource, vendored binary, or fixture in a
    /// checked-out build is a broken build, not "nothing to check" — so
    /// these fail hard rather than XCTSkip. See SVGCompressorTests.swift
    /// for the house pattern.
    private struct MissingTestResource: Error {}

    private func makeModel() throws -> (AppModel, Settings) {
        let repoRoot = ProcessInfo.processInfo.environment["SRCROOT"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let vendor = repoRoot.appendingPathComponent("vendor/compressors")
        guard FileManager.default.isExecutableFile(atPath: vendor.appendingPathComponent("cjpeg").path) else {
            XCTFail("compressors not built — run scripts/build-compressors.sh")
            throw MissingTestResource()
        }
        let bundle = Bundle(for: AppModelTests.self)
        guard let svgo = bundle.url(forResource: "svgo.jsc", withExtension: "js")
            ?? Bundle.main.url(forResource: "svgo.jsc", withExtension: "js") else {
            XCTFail("svgo.jsc.js not bundled — run scripts/prepare-svgo.sh, then xcodegen generate")
            throw MissingTestResource()
        }
        let engine = try ShrinkEngine(
            helperProvider: { vendor.appendingPathComponent($0) }, svgoScriptURL: svgo
        )
        let settings = Settings(defaults: UserDefaults(suiteName: "appmodel-\(UUID().uuidString)")!)
        return (AppModel(engine: engine, settings: settings, notifier: nil), settings)
    }

    private func stagedPNG() throws -> URL {
        let bundle = Bundle(for: AppModelTests.self)
        guard let source = bundle.url(forResource: "sample", withExtension: "png", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "sample", withExtension: "png") else {
            XCTFail("fixture sample.png not found in test bundle — check project.yml's Fixtures resource entry and re-run xcodegen generate")
            throw MissingTestResource()
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("am-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let staged = dir.appendingPathComponent("sample.png")
        try FileManager.default.copyItem(at: source, to: staged)
        return staged
    }

    func testSuccessfulDropAddsRow() async throws {
        let (model, _) = try makeModel()
        let file = try stagedPNG()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        await model.process(urls: [file])

        XCTAssertEqual(model.rows.count, 1)
        XCTAssertGreaterThan(model.rows[0].savedPercent, 0)
        XCTAssertFalse(model.isProcessing)
        XCTAssertNil(model.errorMessage)
    }

    func testNewestResultAppearsFirst() async throws {
        let (model, _) = try makeModel()
        let a = try stagedPNG(), b = try stagedPNG()
        defer {
            try? FileManager.default.removeItem(at: a.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: b.deletingLastPathComponent())
        }
        await model.process(urls: [a])
        await model.process(urls: [b])

        XCTAssertEqual(model.rows.count, 2)
        XCTAssertEqual(model.rows.first?.output.path,
                       b.deletingLastPathComponent().appendingPathComponent("sample.min.png").path,
                       "newest result must be prepended, matching upstream resultBox.prepend")
    }

    func testRowsCarryByteCountsMatchingTheStagedFile() async throws {
        let (model, _) = try makeModel()
        let file = try stagedPNG()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let expectedOriginalBytes = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int

        await model.process(urls: [file])

        guard let row = model.rows.first else {
            XCTFail("expected a row after processing")
            return
        }
        XCTAssertEqual(row.originalBytes, expectedOriginalBytes, "row.originalBytes must match the real pre-compression file size")
        XCTAssertGreaterThan(row.shrunkBytes, 0)
        XCTAssertLessThan(row.shrunkBytes, row.originalBytes, "sample.png fixture is expected to actually shrink")

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let expectedSummary = "\(formatter.string(fromByteCount: Int64(row.originalBytes))) → \(formatter.string(fromByteCount: Int64(row.shrunkBytes)))"
        XCTAssertEqual(row.sizeSummary, expectedSummary)
    }

    func testSessionAggregateAccumulatesAcrossDrops() async throws {
        let (model, _) = try makeModel()
        let a = try stagedPNG(), b = try stagedPNG()
        defer {
            try? FileManager.default.removeItem(at: a.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: b.deletingLastPathComponent())
        }

        await model.process(urls: [a])
        guard let firstRow = model.rows.first else {
            XCTFail("expected a row after first drop")
            return
        }
        XCTAssertEqual(model.session.fileCount, 1)
        XCTAssertEqual(model.session.bytesSaved, firstRow.originalBytes - firstRow.shrunkBytes)

        await model.process(urls: [b])
        guard let secondRow = model.rows.first else {
            XCTFail("expected a row after second drop")
            return
        }
        XCTAssertEqual(model.session.fileCount, 2, "session should accumulate, not reset, when clearList is off")
        XCTAssertEqual(
            model.session.bytesSaved,
            (firstRow.originalBytes - firstRow.shrunkBytes) + (secondRow.originalBytes - secondRow.shrunkBytes),
            "session.bytesSaved must equal the sum of both rows' actual deltas"
        )
    }

    func testSessionAggregateResetsWhenClearListWipesRows() async throws {
        let (model, settings) = try makeModel()
        settings.clearList = true
        let a = try stagedPNG(), b = try stagedPNG()
        defer {
            try? FileManager.default.removeItem(at: a.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: b.deletingLastPathComponent())
        }

        await model.process(urls: [a])
        XCTAssertEqual(model.session.fileCount, 1)

        await model.process(urls: [b])
        guard model.rows.count == 1, let onlyRow = model.rows.first else {
            XCTFail("clearList should leave exactly one row after the second batch")
            return
        }
        XCTAssertEqual(model.session.fileCount, 1, "session aggregate must reset when clearList wipes the row list")
        XCTAssertEqual(model.session.bytesSaved, onlyRow.originalBytes - onlyRow.shrunkBytes)
    }

    func testClearListSettingResetsBetweenDrops() async throws {
        let (model, settings) = try makeModel()
        settings.clearList = true
        let a = try stagedPNG(), b = try stagedPNG()
        defer {
            try? FileManager.default.removeItem(at: a.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: b.deletingLastPathComponent())
        }
        await model.process(urls: [a])
        await model.process(urls: [b])

        XCTAssertEqual(model.rows.count, 1, "clearList should reset the list on each new batch")
    }

    // MARK: - clearHistory (explicit user action, distinct from the clearList setting)

    /// `clearHistory()` must empty both `rows` and `session` (not just one
    /// of the two — a stale session count next to an empty list would be
    /// its own kind of bug), and must not misbehave when called again with
    /// nothing left to clear.
    func testClearHistoryEmptiesRowsAndResetsSessionAndToleratesRepeatCalls() async throws {
        let (model, _) = try makeModel()
        let file = try stagedPNG()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        await model.process(urls: [file])
        XCTAssertEqual(model.rows.count, 1, "sanity check: a drop should have produced a row before clearing")
        XCTAssertGreaterThan(model.session.fileCount, 0, "sanity check: session should be non-zero before clearing")

        model.clearHistory()

        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.session, SessionSummary())

        // Calling it again with nothing left must not crash or misbehave.
        model.clearHistory()

        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.session, SessionSummary())
    }

    func testUnsupportedFileSurfacesError() async throws {
        let (model, _) = try makeModel()
        let bogus = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("x.txt")
        try Data("no".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }

        await model.process(urls: [bogus])

        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isProcessing)
    }

    func testDroppedDirectoryIsExpanded() async throws {
        let (model, _) = try makeModel()
        let file = try stagedPNG()
        let folder = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }

        await model.process(urls: [folder])

        XCTAssertEqual(model.rows.count, 1, "upstream traverseFileTree recurses into dropped folders")
    }

    // MARK: - Folder expansion boundaries

    /// Builds a folder containing one ordinary image plus two images the
    /// expansion must refuse to reach: one inside a package (`Fake.app`)
    /// and one inside a hidden directory.
    private func folderWithTraps() throws -> URL {
        let bundle = Bundle(for: AppModelTests.self)
        guard let source = bundle.url(forResource: "sample", withExtension: "png", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "sample", withExtension: "png") else {
            XCTFail("fixture sample.png not found in test bundle")
            throw MissingTestResource()
        }
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("traps-\(UUID().uuidString)")
        let inPackage = root.appendingPathComponent("Fake.app/Contents/Resources", isDirectory: true)
        let inHidden = root.appendingPathComponent(".hidden", isDirectory: true)
        for dir in [root, inPackage, inHidden] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for dest in [
            root.appendingPathComponent("visible.png"),
            inPackage.appendingPathComponent("icon.png"),
            inHidden.appendingPathComponent("cached.png"),
        ] {
            try FileManager.default.copyItem(at: source, to: dest)
        }
        return root
    }

    /// Dropping a folder must not walk into bundles inside it. Writing
    /// "icon.min.png" into Foo.app/Contents/Resources/ breaks that app's
    /// code signature, and with suffix and subfolder both off it rewrites
    /// the app's real resources in place. Same for hidden directories:
    /// dropping ~/Pictures should not rewrite the innards of a
    /// .photoslibrary, and dropping a project folder should not rewrite
    /// files under .git.
    func testDroppedFolderDoesNotDescendIntoPackagesOrHiddenDirectories() throws {
        let root = try folderWithTraps()
        defer { try? FileManager.default.removeItem(at: root) }

        let found = AppModel.expand([root])

        XCTAssertEqual(
            found.map(\.lastPathComponent), ["visible.png"],
            "expansion reached files it should not have: \(found.map(\.path))"
        )
        XCTAssertFalse(
            found.contains { $0.pathComponents.contains("Fake.app") },
            "descended into a package — this corrupts app bundles"
        )
        XCTAssertFalse(
            found.contains { $0.pathComponents.contains(".hidden") },
            "descended into a hidden directory"
        )
    }

    /// The exclusion above is about *descending into* packages found while
    /// walking, not about refusing work the user asked for. A package
    /// dropped directly is still handed to the engine as a single item —
    /// where it is rejected as an unsupported format, since ".app" is not a
    /// supported extension. Checking this keeps the fix from being
    /// "silently drops things the user selected".
    func testDirectlyDroppedPackageIsNotExpandedIntoItsContents() throws {
        let root = try folderWithTraps()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Fake.app")

        let found = AppModel.expand([package])

        XCTAssertEqual(
            found, [package],
            "a directly-dropped package should pass through whole, not be expanded"
        )
    }
}
