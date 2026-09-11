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
        let settings = Settings(defaults: makeTestDefaults("appmodel"))
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

    // MARK: - Batch notification summary
    //
    // The notification used to be posted inside the per-file loop, so a
    // six-file drop fired six banners. These cover the summary that replaced
    // it: they are pure functions over results, so they need no engine, no
    // files and no notification permission.

    func testSingleFileNotificationNamesTheFile() {
        let result = ShrinkResult(
            input: URL(fileURLWithPath: "/tmp/hero-banner@2x.png"),
            output: URL(fileURLWithPath: "/tmp/hero-banner@2x.min.png"),
            originalBytes: 1_440_822, shrunkBytes: 524_269
        )
        XCTAssertEqual(AppModel.notificationTitle(count: 1), "Image shrunk")
        XCTAssertEqual(AppModel.notificationBody(for: [result]), "hero-banner@2x.min.png")
    }

    func testBatchNotificationCountsFilesAndTotalsSavings() {
        let results = [
            ShrinkResult(input: URL(fileURLWithPath: "/tmp/a.png"),
                         output: URL(fileURLWithPath: "/tmp/a.min.png"),
                         originalBytes: 1_000_000, shrunkBytes: 400_000),
            ShrinkResult(input: URL(fileURLWithPath: "/tmp/b.jpg"),
                         output: URL(fileURLWithPath: "/tmp/b.min.jpg"),
                         originalBytes: 500_000, shrunkBytes: 100_000),
        ]
        XCTAssertEqual(AppModel.notificationTitle(count: 2), "2 images shrunk")
        // 1,000,000 saved across the batch. ByteCountFormatter's exact
        // wording is locale-dependent, so assert the number is reported
        // rather than pinning a string the formatter owns.
        let body = AppModel.notificationBody(for: results)
        XCTAssertTrue(body.contains("saved"), "expected a savings summary, got \(body)")
        XCTAssertTrue(body.contains("1") && (body.contains("MB") || body.contains("KB")),
                      "expected a formatted byte total, got \(body)")
    }

    func testBatchNotificationDoesNotReportNegativeSavings() {
        // A file that grew (upstream's savedPercent can go negative) must not
        // produce a nonsensical negative total.
        let grew = ShrinkResult(input: URL(fileURLWithPath: "/tmp/c.gif"),
                                output: URL(fileURLWithPath: "/tmp/c.min.gif"),
                                originalBytes: 1000, shrunkBytes: 1200)
        let shrank = ShrinkResult(input: URL(fileURLWithPath: "/tmp/d.png"),
                                  output: URL(fileURLWithPath: "/tmp/d.min.png"),
                                  originalBytes: 1000, shrunkBytes: 100)
        let body = AppModel.notificationBody(for: [grew, shrank])
        XCTAssertFalse(body.contains("-"), "savings total should never render negative, got \(body)")
    }
}

// MARK: - The session conversion override

@MainActor
final class SessionOverrideTests: XCTestCase {

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
        let bundle = Bundle(for: SessionOverrideTests.self)
        guard let svgo = bundle.url(forResource: "svgo.jsc", withExtension: "js")
            ?? Bundle.main.url(forResource: "svgo.jsc", withExtension: "js") else {
            XCTFail("svgo.jsc.js not bundled — run scripts/prepare-svgo.sh, then xcodegen generate")
            throw MissingTestResource()
        }
        let engine = try ShrinkEngine(
            helperProvider: { vendor.appendingPathComponent($0) }, svgoScriptURL: svgo
        )
        let settings = Settings(defaults: makeTestDefaults("session-override"))
        return (AppModel(engine: engine, settings: settings, notifier: nil), settings)
    }

    private func staged(_ name: String, _ ext: String) throws -> URL {
        let bundle = Bundle(for: SessionOverrideTests.self)
        guard let source = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: ext) else {
            XCTFail("fixture \(name).\(ext) not found in test bundle")
            throw MissingTestResource()
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let staged = dir.appendingPathComponent("\(name).\(ext)")
        try FileManager.default.copyItem(at: source, to: staged)
        return staged
    }

    func testDefaultsToOff() throws {
        let (model, _) = try makeModel()
        XCTAssertNil(model.sessionFormat, "the app must behave exactly as before until the override is set")
    }

    func testAnOverrideConvertsADroppedFile() async throws {
        let (model, _) = try makeModel()
        model.sessionFormat = .webp

        await model.process(urls: [try staged("sample", "png")])

        XCTAssertEqual(model.rows.first?.output.pathExtension, "webp")
    }

    func testClearingTheOverrideRestoresTheStoredRules() async throws {
        let (model, _) = try makeModel()
        model.sessionFormat = .webp
        await model.process(urls: [try staged("sample", "png")])
        XCTAssertEqual(model.rows.first?.output.pathExtension, "webp")

        model.sessionFormat = nil
        await model.process(urls: [try staged("sample", "png")])

        XCTAssertEqual(model.rows.first?.output.pathExtension, "png")
    }

    /// The override is session state and must never reach the defaults
    /// database — a fresh `Settings` over the same suite must not see it.
    func testTheOverrideIsNeverPersisted() async throws {
        let (model, settings) = try makeModel()
        model.sessionFormat = .avif
        await model.process(urls: [try staged("sample", "png")])

        XCTAssertNil(
            settings.outputSettings.sessionFormat,
            "the override must not be written into the settings snapshot"
        )
        XCTAssertEqual(settings.pngConversion, .keep, "the stored rules must be left exactly as they were")
    }

    func testSVGAndGIFAreUnaffected() async throws {
        let (model, _) = try makeModel()
        model.sessionFormat = .jpeg

        await model.process(urls: [try staged("sample", "svg"), try staged("sample", "gif")])

        let extensions = Set(model.rows.map(\.output.pathExtension))
        XCTAssertEqual(extensions, ["svg", "gif"])
    }
}
