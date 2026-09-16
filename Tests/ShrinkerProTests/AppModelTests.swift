import XCTest
import CoreGraphics
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

    /// The last hop nothing else covers: `Settings` → the per-batch snapshot
    /// `process(urls:)` builds → the engine. `QualitySettingTests` proves
    /// `Settings` projects the level into `outputSettings`; this proves a real
    /// drop is actually encoded with it.
    ///
    /// Routed PNG → WebP deliberately. A same-format PNG drop goes to
    /// pngquant, which ignores quality by design, so it would pass whether or
    /// not the setting were plumbed through at all — the test would be
    /// vacuous in exactly the way that matters.
    func testTheQualitySettingChangesWhatADropActuallyProduces() async throws {
        func shrunkBytes(at quality: QualityLevel) async throws -> Int {
            let (model, settings) = try makeModel()
            settings.pngConversion = .webp
            settings.quality = quality

            let file = try stagedPNG()
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

            await model.process(urls: [file])
            guard let row = model.rows.first else {
                XCTFail("expected a row after processing at \(quality.displayName)")
                return 0
            }
            return row.shrunkBytes
        }

        let low = try await shrunkBytes(at: .low)
        let high = try await shrunkBytes(at: .high)

        XCTAssertLessThan(
            low, high,
            "the Quality setting must change what a drop actually writes to disk"
        )
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

        let found = InputExpander.expand([root])

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

        let found = InputExpander.expand([package])

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

    // MARK: - The max size, the window's other session setting

    func testTheMaxSizeDefaultsToOff() throws {
        let (model, _) = try makeModel()

        XCTAssertEqual(model.sessionMaxSizeText, "")
        XCTAssertNil(model.sessionMaxDimension, "no resizing until a number is typed")
    }

    /// The field filters itself as it is typed, so a rejected character never
    /// appears in it — there is no commit step where it could be cleaned up
    /// later.
    func testTheFieldFiltersWhatIsTypedIntoIt() throws {
        let (model, _) = try makeModel()

        model.sessionMaxSizeText = "2a0*0/0"

        XCTAssertEqual(model.sessionMaxSizeText, "2000")
        XCTAssertEqual(model.sessionMaxDimension, 2000)
    }

    /// Typed, not committed: a value is in force the moment it is entered,
    /// which is the whole reason the field holds text rather than a number.
    func testATypedValueResizesADroppedFileWithoutBeingCommitted() async throws {
        let (model, _) = try makeModel()
        model.sessionMaxSizeText = "100"

        await model.process(urls: [try staged("sample", "png")])

        let output = try XCTUnwrap(model.rows.first?.output)
        let size = try XCTUnwrap(ImageMetadata.header(of: output).pixelSize)
        XCTAssertEqual(max(size.width, size.height), 100, accuracy: 1)
    }

    /// Session state, like the format override: it must never reach the
    /// defaults database.
    func testTheMaxSizeIsNeverPersisted() async throws {
        let (model, settings) = try makeModel()
        model.sessionMaxSizeText = "100"

        await model.process(urls: [try staged("sample", "png")])

        XCTAssertNil(
            settings.outputSettings.maxDimension,
            "the max size must not be written into the settings snapshot"
        )
    }

    // MARK: - Quality, which is now session state too

    /// Untouched means "whatever Settings says", not a copy of it taken at
    /// launch — so changing the stored default mid-session is still felt.
    func testAnUntouchedQualityFollowsTheStoredDefault() async throws {
        let (model, settings) = try makeModel()
        settings.quality = .superLow

        XCTAssertNil(model.sessionQuality)

        await model.process(urls: [try staged("sample", "jpg")])
        let atSuperLow = try XCTUnwrap(model.rows.first?.shrunkBytes)

        settings.quality = .high
        model.clearHistory()
        await model.process(urls: [try staged("sample", "jpg")])
        let atHigh = try XCTUnwrap(model.rows.first?.shrunkBytes)

        XCTAssertLessThan(atSuperLow, atHigh, "the stored default must still reach the engine")
    }

    /// The change this bar made: choosing a quality in the window no longer
    /// writes to UserDefaults. It applies to the session and the stored
    /// default is left exactly as it was.
    func testChoosingAQualityInTheBarDoesNotPersistIt() async throws {
        let (model, settings) = try makeModel()
        settings.quality = .standard

        model.sessionQuality = .superLow
        await model.process(urls: [try staged("sample", "jpg")])

        XCTAssertEqual(
            settings.quality, .standard,
            "the session's quality must not be written back over the stored default"
        )
    }

    func testTheSessionQualityReachesTheEngine() async throws {
        let (model, settings) = try makeModel()
        settings.quality = .high

        model.sessionQuality = .superLow
        await model.process(urls: [try staged("sample", "jpg")])
        let overridden = try XCTUnwrap(model.rows.first?.shrunkBytes)

        model.sessionQuality = nil
        model.clearHistory()
        await model.process(urls: [try staged("sample", "jpg")])
        let stored = try XCTUnwrap(model.rows.first?.shrunkBytes)

        XCTAssertLessThan(overridden, stored, "Super Low for this session must beat a stored High")
    }

    // MARK: - Reset

    func testResetReturnsEverySessionSettingToTheAppDefaults() throws {
        let (model, _) = try makeModel()
        model.sessionFormat = .png
        model.sessionQuality = .superLow
        model.sessionMaxSizeText = "1200"

        model.resetSessionSettings()

        XCTAssertNil(model.sessionFormat)
        XCTAssertNil(model.sessionQuality)
        XCTAssertEqual(model.sessionMaxSizeText, "")
        XCTAssertNil(model.sessionMaxDimension)
    }

    /// Reset is about the session, so it must leave the stored preferences
    /// alone — including the quality it is visually "resetting".
    func testResetLeavesStoredSettingsAlone() throws {
        let (model, settings) = try makeModel()
        settings.quality = .high
        settings.pngConversion = .webp
        model.sessionQuality = .low

        model.resetSessionSettings()

        XCTAssertEqual(settings.quality, .high)
        XCTAssertEqual(settings.pngConversion, .webp)
    }

    // MARK: - The panel

    /// Closing is where an out-of-range number settles, because it is the
    /// one moment Done, Escape, a click outside and a drop all share.
    func testClosingThePanelSnapsAnOutOfRangeMaxSize() throws {
        let (model, _) = try makeModel()
        model.setSessionPanel(expanded: true)
        model.sessionMaxSizeText = "99999"

        model.setSessionPanel(expanded: false)

        XCTAssertEqual(model.sessionMaxSizeText, "20000")
        XCTAssertEqual(model.sessionMaxDimension, 20_000)
    }

    func testThePanelStartsClosedAndADropClosesIt() async throws {
        let (model, _) = try makeModel()
        XCTAssertFalse(model.isSessionPanelExpanded)

        model.setSessionPanel(expanded: true)
        model.handle(urls: [try staged("sample", "png")])

        XCTAssertFalse(
            model.isSessionPanelExpanded,
            "a drop answers the question the panel was asking"
        )
    }
}

// MARK: - The overwrite guard

@MainActor
final class OverwriteFlowTests: XCTestCase {

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
        let bundle = Bundle(for: Self.self)
        guard let svgo = bundle.url(forResource: "svgo.jsc", withExtension: "js")
            ?? Bundle.main.url(forResource: "svgo.jsc", withExtension: "js") else {
            XCTFail("svgo.jsc.js not bundled — run scripts/prepare-svgo.sh, then xcodegen generate")
            throw MissingTestResource()
        }
        let engine = try ShrinkEngine(
            helperProvider: { vendor.appendingPathComponent($0) }, svgoScriptURL: svgo
        )
        let settings = Settings(defaults: makeTestDefaults("overwrite-flow"))
        return (AppModel(engine: engine, settings: settings, notifier: nil), settings)
    }

    private func staged(_ name: String = "sample") throws -> URL {
        let repoRoot = ProcessInfo.processInfo.environment["SRCROOT"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = repoRoot.appendingPathComponent("Tests/ShrinkerProTests/Fixtures/sample.png")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let staged = dir.appendingPathComponent("\(name).png")
        try FileManager.default.copyItem(at: source, to: staged)
        return staged
    }

    /// Answers the sheet as soon as one appears, so `process` can complete.
    ///
    /// Bounded on the wall clock, and that is not a nicety. An unbounded spin
    /// on the main actor turns "no sheet was ever raised" into a hung test
    /// host rather than a failing test: XCTest's own timers are scheduled on
    /// the main run loop, which a saturated main actor never lets fire. That
    /// cost ten minutes of a wedged run once already — see
    /// `testASecondBatchWhileASheetIsUpDoesNotStrandTheFirst`.
    private func answering(_ answer: OverwriteAnswer, on model: AppModel) -> Task<Void, Never> {
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(10)
            while model.pendingOverwrite == nil, Date() < deadline, !Task.isCancelled {
                await Task.yield()
            }
            model.answerOverwrite(answer)
        }
    }

    /// Stages several fixtures side by side in one directory, so a single drop
    /// can carry files that collide in different ways.
    private func stagedFolder(_ names: [String]) throws -> URL {
        let repoRoot = ProcessInfo.processInfo.environment["SRCROOT"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        for name in names {
            try FileManager.default.copyItem(
                at: repoRoot.appendingPathComponent("Tests/ShrinkerProTests/Fixtures/\(name)"),
                to: dir.appendingPathComponent(name)
            )
        }
        return dir
    }

    func testAFirstRunAsksNothing() async throws {
        let (model, _) = try makeModel()

        await model.process(urls: [try staged()])

        XCTAssertNil(model.pendingOverwrite, "nothing was there to replace")
        XCTAssertEqual(model.rows.count, 1)
    }

    /// The requester's own scenario: shrink, then shrink again.
    func testASecondRunOverTheSameFileAsks() async throws {
        let (model, _) = try makeModel()
        let file = try staged()
        await model.process(urls: [file])

        let responder = answering(.replace, on: model)
        await model.process(urls: [file])
        await responder.value

        XCTAssertEqual(model.rows.count, 2, "replacing still produces a result")
    }

    /// With the setting off the code path must be exactly 1.2.0's.
    func testNothingIsAskedWhenTheWarningIsTurnedOff() async throws {
        let (model, settings) = try makeModel()
        settings.warnBeforeOverwrite = false
        let file = try staged()
        await model.process(urls: [file])

        // A watchdog rather than no responder at all. With the setting off no
        // sheet may appear — but if one ever did, nothing here would answer it
        // and `process` would hang the test host instead of failing. This
        // answers it and records that it happened, so the assertion below is
        // what reports the regression.
        let log = SheetLog()
        let watchdog = Task { @MainActor in
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, !Task.isCancelled {
                if model.pendingOverwrite != nil {
                    log.sawAnySheet = true
                    model.answerOverwrite(.skip)
                }
                await Task.yield()
            }
        }
        await model.process(urls: [file])
        watchdog.cancel()

        XCTAssertFalse(log.sawAnySheet, "the warning is off: nothing may be asked")
        XCTAssertNil(model.pendingOverwrite)
        XCTAssertEqual(model.rows.count, 2)
    }

    func testSkippingLeavesTheExistingFileByteForByte() async throws {
        let (model, _) = try makeModel()
        let file = try staged()
        await model.process(urls: [file])
        let output = file.deletingLastPathComponent().appendingPathComponent("sample.min.png")
        let before = try Data(contentsOf: output)

        let responder = answering(.skip, on: model)
        await model.process(urls: [file])
        await responder.value

        XCTAssertEqual(try Data(contentsOf: output), before, "skip must not write")
        XCTAssertEqual(model.rows.count, 1, "a skipped file produces no row")
        XCTAssertNil(model.errorMessage, "skipping is a choice, not a failure")
    }

    func testKeepBothWritesANumberedSibling() async throws {
        let (model, _) = try makeModel()
        let file = try staged()
        await model.process(urls: [file])

        let responder = answering(.keepBoth, on: model)
        await model.process(urls: [file])
        await responder.value

        let folder = file.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("sample.min.png").path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("sample.min 2.png").path),
            "Keep Both must leave both files on disk"
        )
    }

    /// Skipping one file must not abandon the rest of the drop.
    func testUncollidingFilesInTheSameBatchStillRun() async throws {
        let (model, _) = try makeModel()
        let collides = try staged("collides")
        await model.process(urls: [collides])
        let fresh = try staged("fresh")

        let responder = answering(.skip, on: model)
        await model.process(urls: [collides, fresh])
        await responder.value

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fresh.deletingLastPathComponent().appendingPathComponent("fresh.min.png").path
            ),
            "the file nobody was asked about must still have been shrunk"
        )
    }

    /// The sheet must describe the second category, not the first: with
    /// "Keep originals" on, a re-run threatens the .min copy, not the source.
    func testARerunAsksAboutTheExistingFileNotTheOriginal() async throws {
        let (model, _) = try makeModel()
        let file = try staged()
        await model.process(urls: [file])

        // Bounded for the same reason as `answering(_:on:)` above: a sheet
        // that never arrives must fail this test, not wedge the host.
        let observer = Task { @MainActor () -> OverwriteCategory? in
            let deadline = Date().addingTimeInterval(10)
            while model.pendingOverwrite == nil, Date() < deadline { await Task.yield() }
            let category = model.pendingOverwrite?.category
            model.answerOverwrite(.skip)
            return category
        }
        await model.process(urls: [file])

        // A `.original` here, or no sheet at all (nil), fails.
        let category = await observer.value
        XCTAssertEqual(
            category, .existingFile,
            "the sheet must be about the file already there, not the original"
        )
    }

    /// One continuation is stored at a time, so a second batch that reaches a
    /// sheet while the first is still waiting would strand the first one —
    /// and a continuation nobody ever resumes hangs its batch for the life of
    /// the process. Two batches genuinely can overlap: `handle(urls:)` starts
    /// a task per drop, and a Finder "Open With", a Dock drop or an Open
    /// Recent click all reach it while a sheet is up.
    ///
    /// Waits on a wall-clock deadline rather than an `XCTestExpectation`, and
    /// that is not a style preference. XCTest's expectation timers are
    /// scheduled on the main run loop, which a stranded main-actor batch
    /// leaves saturated — so the timeout never fires and the whole run wedges
    /// instead of this one test failing. Measured against the mutation below:
    /// an expectation-based first draft hung the test host for over ten
    /// minutes. Polling `Date()` depends on nothing but the clock, so the
    /// failure is always clean and bounded.
    func testASecondBatchWhileASheetIsUpDoesNotStrandTheFirst() async throws {
        let (model, _) = try makeModel()
        let first = try staged("first")
        let second = try staged("second")
        await model.process(urls: [first])
        await model.process(urls: [second])

        // Both destinations are now occupied, so both batches must ask.
        //
        // The responder deliberately does NOT answer the first question it
        // sees. Answering immediately lets the two batches queue up one after
        // the other — a sequence that works whether or not anything guards
        // the single continuation slot, and a first draft of this test that
        // did exactly that passed even with the guard deleted. Waiting until
        // a *second, different* request has replaced the first is what forces
        // the overlap: at that moment two batches are both waiting and only
        // one continuation is stored. The single answer below releases the
        // second batch; the first can only finish if something resumed the
        // continuation it was displaced from.
        let flags = BatchFlags()
        let responder = Task { @MainActor in
            let overlapBy = Date().addingTimeInterval(5)
            while model.pendingOverwrite == nil, Date() < overlapBy, !Task.isCancelled {
                await Task.yield()
            }
            let firstQuestion = model.pendingOverwrite?.id
            while model.pendingOverwrite?.id == firstQuestion, Date() < overlapBy, !Task.isCancelled {
                await Task.yield()
            }
            model.answerOverwrite(.skip)
        }
        Task { @MainActor in
            await model.process(urls: [first])
            flags.firstFinished = true
        }
        Task { @MainActor in
            await model.process(urls: [second])
            flags.secondFinished = true
        }

        let deadline = Date().addingTimeInterval(20)
        while !(flags.firstFinished && flags.secondFinished), Date() < deadline {
            await Task.yield()
        }
        responder.cancel()

        XCTAssertTrue(
            flags.firstFinished,
            "the first batch never returned — nothing resumed the continuation it was displaced from"
        )
        XCTAssertTrue(flags.secondFinished, "the second batch never returned")
    }

    /// The configuration that motivated having two sheets at all: one file
    /// whose output would land on the user's own original, and another whose
    /// converted output would land on a different file already sitting there.
    /// Both questions must be asked, the irreversible one first, and each
    /// answer honoured independently — "keep both of my originals, but
    /// replace the stale copies".
    ///
    /// It is also the shape that catches a sheet counting the *other* sheet's
    /// files as unaffected, which is the worst thing this feature could do:
    /// tell the user a file is safe immediately before offering to replace it.
    func testADropWithBothKindsOfCollisionAsksTwiceInStakesOrder() async throws {
        let (model, settings) = try makeModel()
        // Outputs take their input's own name, so a same-format file's
        // destination IS its input — the first category.
        settings.keepOriginal = false
        // ...while the JPEG converts, so its destination is a .webp that is
        // already on disk — the second category, in the same drop.
        settings.jpegConversion = .webp

        let folder = try stagedFolder(["sample.png", "sample.jpg", "sample.webp"])
        let png = folder.appendingPathComponent("sample.png")
        let jpg = folder.appendingPathComponent("sample.jpg")
        let webp = folder.appendingPathComponent("sample.webp")
        let pngBefore = try Data(contentsOf: png)
        let webpBefore = try Data(contentsOf: webp)

        let log = SheetLog()
        let responder = Task { @MainActor in
            let deadline = Date().addingTimeInterval(10)
            while log.categories.count < 2, Date() < deadline, !Task.isCancelled {
                guard let request = model.pendingOverwrite else {
                    await Task.yield()
                    continue
                }
                log.unaffectedCounts.append(request.unaffectedCount)
                switch request.category {
                case .original:
                    log.categories.append(.original)
                    model.answerOverwrite(.keepBoth)
                case .existingFile:
                    log.categories.append(.existingFile)
                    model.answerOverwrite(.replace)
                }
            }
        }
        await model.process(urls: [png, jpg])
        responder.cancel()

        XCTAssertEqual(
            log.categories, [.original, .existingFile],
            "both questions must be asked, and the irreversible one first"
        )
        XCTAssertEqual(
            log.unaffectedCounts.first, 0,
            "every file in this drop is about to be asked about — none may be called unaffected"
        )
        XCTAssertEqual(
            try Data(contentsOf: png), pngBefore,
            "Keep Both must leave the original exactly as it was"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("sample 2.png").path),
            "Keep Both must write the result beside the original it spared"
        )
        XCTAssertNotEqual(
            try Data(contentsOf: webp), webpBefore,
            "Replace must actually replace the file already there"
        )
    }

    /// `InputExpander` does not de-duplicate, so dropping a folder together
    /// with a file inside it plans the same file twice. Under Keep Both both
    /// plans are redirected, and `OutputPathResolver.uniqueDestination` can
    /// only see what is on disk — never what this batch has already claimed —
    /// so unless the batch tracks its own claims both pick the same "… 2"
    /// name and the second write destroys the first. Data loss in the one
    /// path whose entire purpose is not losing data.
    func testKeepBothGivesDuplicatePlansDistinctFiles() async throws {
        let (model, _) = try makeModel()
        let file = try staged()
        let folder = file.deletingLastPathComponent()
        await model.process(urls: [file])

        // The realistic route to a duplicate, asserted rather than assumed:
        // a folder and a file inside it, dropped together.
        XCTAssertEqual(
            InputExpander.expand([folder, file]).filter { $0.lastPathComponent == "sample.png" }.count, 2,
            "expansion is expected to yield the same file twice — that is the case under test"
        )

        let responder = answering(.keepBoth, on: model)
        await model.process(urls: [file, file])
        await responder.value

        let produced = try FileManager.default
            .contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("sample.min") }
            .sorted()
        XCTAssertEqual(
            produced, ["sample.min 2.png", "sample.min 3.png", "sample.min.png"],
            "two duplicate plans must land on two distinct new files, not both on one"
        )
    }

    /// A Keep Both redirect must not land on a path another plan in the same
    /// batch is *already* going to write — including a plan no sheet ever
    /// mentioned, because its own destination was free.
    ///
    /// With originals replaced into `minified/`, `photo.png` collides with a
    /// `minified/photo.png` already there, while `photo 2.png` heads for a
    /// free `minified/photo 2.png`. The first free numbered name for the
    /// redirect is exactly that path, so unless the batch reserves every
    /// plan's destination up front, both write it and the second destroys the
    /// first.
    func testKeepBothDoesNotRedirectOntoAnotherPlansDestination() async throws {
        let (model, settings) = try makeModel()
        settings.keepOriginal = false
        settings.useSubfolder = true

        // Two different images, so the two outputs can be told apart.
        let folder = try stagedFolder(["sample.png", "rotated.png"])
        let photo = folder.appendingPathComponent("photo.png")
        let photo2 = folder.appendingPathComponent("photo 2.png")
        try FileManager.default.moveItem(at: folder.appendingPathComponent("sample.png"), to: photo)
        try FileManager.default.moveItem(at: folder.appendingPathComponent("rotated.png"), to: photo2)

        let minified = folder.appendingPathComponent("minified", isDirectory: true)
        try FileManager.default.createDirectory(at: minified, withIntermediateDirectories: true)
        let occupant = Data("already here".utf8)
        try occupant.write(to: minified.appendingPathComponent("photo.png"))

        let responder = answering(.keepBoth, on: model)
        await model.process(urls: [photo, photo2])
        await responder.value

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(
            try Data(contentsOf: minified.appendingPathComponent("photo.png")), occupant,
            "Keep Both must leave the file already there untouched"
        )
        let produced = try FileManager.default.contentsOfDirectory(atPath: minified.path).sorted()
        XCTAssertEqual(
            produced, ["photo 2.png", "photo 3.png", "photo.png"],
            "the redirect must skip the name the uncolliding file is about to write"
        )
        let second = try Data(contentsOf: minified.appendingPathComponent("photo 2.png"))
        let third = try Data(contentsOf: minified.appendingPathComponent("photo 3.png"))
        XCTAssertNotEqual(second, third, "two different inputs must leave two different outputs")
        XCTAssertEqual(model.rows.count, 2, "both files must have been shrunk")
    }

    /// The batch reserves every plan's destination, and a plan's own
    /// reservation must not block that plan — but must still block a
    /// duplicate of it.
    ///
    /// Only reachable when the occupying file disappears while the sheet is
    /// up, so that is what this does: two duplicate plans, the occupant
    /// deleted before Keep Both is answered. One plan may take the now-free
    /// name; the other must not take it too.
    func testKeepBothAfterTheOccupantVanishesStillGivesDuplicatesDistinctFiles() async throws {
        let (model, _) = try makeModel()
        let file = try staged()
        let folder = file.deletingLastPathComponent()
        await model.process(urls: [file])
        let occupant = folder.appendingPathComponent("sample.min.png")

        let responder = Task { @MainActor in
            let deadline = Date().addingTimeInterval(10)
            while model.pendingOverwrite == nil, Date() < deadline, !Task.isCancelled {
                await Task.yield()
            }
            try? FileManager.default.removeItem(at: occupant)
            model.answerOverwrite(.keepBoth)
        }
        await model.process(urls: [file, file])
        await responder.value

        let produced = try FileManager.default
            .contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("sample.min") }
            .sorted()
        XCTAssertEqual(
            produced, ["sample.min 2.png", "sample.min.png"],
            "one plan reclaims the freed name, the other gets a number — never both on one path"
        )
    }
}

/// Whether each of two overlapping batches actually returned. A small
/// main-actor box because Swift 6 will not let two tasks mutate a captured
/// local `var`, and both batches and the test that reads them are already
/// confined to the main actor.
@MainActor
private final class BatchFlags {
    var firstFinished = false
    var secondFinished = false
}

/// What the sheets said, in the order they were raised.
@MainActor
private final class SheetLog {
    var categories: [OverwriteCategory] = []
    var unaffectedCounts: [Int] = []
    var sawAnySheet = false
}
