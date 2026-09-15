import XCTest
@testable import ShrinkerPro

/// The five-part contract every stored preference in this project gets —
/// with one deliberate inversion. The other keys prove they reach the
/// engine snapshot; this one proves it does NOT, because whether to ask a
/// question is a window concern and `OutputSettings` is what a headless
/// run consumes. See `testTheSnapshotCarriesNoSessionOverride` for the
/// same shape applied to the session override.
@MainActor
final class OverwriteWarningSettingTests: XCTestCase {

    func testDefaultsToWarning() {
        let settings = Settings(defaults: makeTestDefaults("warn"))
        XCTAssertTrue(
            settings.warnBeforeOverwrite,
            "the one default in this app that deliberately changes behaviour on upgrade"
        )
    }

    func testItPersists() {
        let defaults = makeTestDefaults("warn")
        Settings(defaults: defaults).warnBeforeOverwrite = false

        XCTAssertFalse(Settings(defaults: defaults).warnBeforeOverwrite)
    }

    func testItPersistsUnderItsPlainName() {
        let defaults = makeTestDefaults("warn")
        Settings(defaults: defaults).warnBeforeOverwrite = false

        XCTAssertEqual(
            defaults.object(forKey: "warnBeforeOverwrite") as? Bool, false,
            "the stored spelling is a compatibility surface — renaming it resets everyone"
        )
    }

    /// `defaults.bool(forKey:)` returns `false` for a value of the wrong
    /// type, and `false` here means "destroy files without asking". A
    /// corrupted store must fail towards the safe answer, which is the same
    /// argument `readQuality` makes about reading a corrupt store as
    /// "quality zero".
    func testACorruptStoredValueFallsBackToWarningRatherThanSilence() {
        let defaults = makeTestDefaults("warn")
        defaults.set("not-a-bool", forKey: "warnBeforeOverwrite")

        XCTAssertTrue(Settings(defaults: defaults).warnBeforeOverwrite)
    }

    /// It is a window concern, not an engine one. Nothing in `OutputSettings`
    /// should ever carry it, or the CLI would inherit a question it cannot ask.
    func testItNeverReachesTheEngineSnapshot() {
        let settings = Settings(defaults: makeTestDefaults("warn"))
        let mirror = Mirror(reflecting: settings.outputSettings)

        XCTAssertFalse(
            mirror.children.contains { $0.label == "warnBeforeOverwrite" },
            "OutputSettings must not carry a UI prompting policy"
        )
    }
}

// MARK: - Which combinations actually replace an original

/// Today's caption claims originals are overwritten whenever the suffix is
/// off. Three of the four combinations below make that a false alarm, and
/// the fourth is the only one that earns a warning.
final class OutputWarningTests: XCTestCase {

    private let elsewhere = URL(fileURLWithPath: "/tmp/shrunk")

    func testKeepingOriginalsNeverReplacesAnything() {
        for sameFolder in [true, false] {
            for subfolder in [true, false] {
                XCTAssertFalse(
                    OutputWarning.replacesOriginals(
                        keepOriginal: true, saveInSameFolder: sameFolder,
                        savePath: sameFolder ? nil : elsewhere, useSubfolder: subfolder
                    ),
                    ".min makes the name differ, whatever else is set"
                )
            }
        }
    }

    func testReplacingInTheSameFolderWithNoSubfolderIsTheOneRiskyCase() {
        XCTAssertTrue(
            OutputWarning.replacesOriginals(
                keepOriginal: false, saveInSameFolder: true, savePath: nil, useSubfolder: false
            )
        )
    }

    func testASubfolderTakesTheOutputOutOfHarmsWay() {
        XCTAssertFalse(
            OutputWarning.replacesOriginals(
                keepOriginal: false, saveInSameFolder: true, savePath: nil, useSubfolder: true
            ),
            "the result lands in minified/, so the original is untouched"
        )
    }

    func testAChosenSaveFolderTakesTheOutputOutOfHarmsWay() {
        XCTAssertFalse(
            OutputWarning.replacesOriginals(
                keepOriginal: false, saveInSameFolder: false, savePath: elsewhere, useSubfolder: false
            )
        )
    }

    /// The subtlety that makes a naive `!saveInSameFolder` check wrong:
    /// `OutputPathResolver` only redirects when a save path actually exists,
    /// and otherwise writes beside the original — so "somewhere else" with
    /// nothing chosen is still the original's own folder.
    func testNotSameFolderButNoFolderChosenStillReplacesTheOriginal() {
        XCTAssertTrue(
            OutputWarning.replacesOriginals(
                keepOriginal: false, saveInSameFolder: false, savePath: nil, useSubfolder: false
            ),
            "no savePath means the resolver falls back to the input's folder"
        )
    }
}

// MARK: - Planning a file without writing it

final class ShrinkPlanTests: XCTestCase {

    private struct MissingTestResource: Error {}

    private func repoRoot() -> URL {
        ProcessInfo.processInfo.environment["SRCROOT"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func makeEngine() throws -> ShrinkEngine {
        let vendor = repoRoot().appendingPathComponent("vendor/compressors")
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
        return try ShrinkEngine(
            helperProvider: { vendor.appendingPathComponent($0) }, svgoScriptURL: svgo
        )
    }

    private func staged(_ name: String, _ ext: String) throws -> URL {
        let source = repoRoot().appendingPathComponent("Tests/ShrinkerProTests/Fixtures/\(name).\(ext)")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let staged = dir.appendingPathComponent("\(name).\(ext)")
        try FileManager.default.copyItem(at: source, to: staged)
        return staged
    }

    private func settings(subfolder: Bool = false, keepOriginal: Bool = true) -> OutputSettings {
        OutputSettings(
            saveInSameFolder: true, savePath: nil,
            useSubfolder: subfolder, keepOriginal: keepOriginal
        )
    }

    func testPlanningNamesTheDestinationWithoutWritingAnything() throws {
        let engine = try makeEngine()
        let input = try staged("sample", "png")

        let plan = try engine.plan(input, settings: settings())

        XCTAssertEqual(plan.input.path, input.path)
        XCTAssertEqual(plan.destination.lastPathComponent, "sample.min.png")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: plan.destination.path),
            "planning must not write the output"
        )
    }

    /// The side effect that used to be buried in path resolution. A scan of
    /// a hundred files must leave no `minified/` folders behind.
    func testPlanningCreatesNoSubfolder() throws {
        let engine = try makeEngine()
        let input = try staged("sample", "png")

        let plan = try engine.plan(input, settings: settings(subfolder: true))

        XCTAssertEqual(plan.destination.deletingLastPathComponent().lastPathComponent, "minified")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: plan.destination.deletingLastPathComponent().path),
            "planning must not create minified/"
        )
    }

    /// HEIC always converts, so its destination is a `.jpg` — which is the
    /// reason a collision scan cannot be done on filenames alone.
    func testPlanningAccountsForConversion() throws {
        let engine = try makeEngine()
        let input = try staged("sample", "heic")

        let plan = try engine.plan(input, settings: settings())

        XCTAssertEqual(plan.destination.pathExtension, "jpg")
    }

    func testExecutingAPlanWritesToItsDestination() throws {
        let engine = try makeEngine()
        let input = try staged("sample", "png")
        let plan = try engine.plan(input, settings: settings())

        let result = try engine.shrink(plan)

        XCTAssertEqual(result.output.path, plan.destination.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.destination.path))
    }

    /// How Keep Both is applied: the plan is redirected, and everything else
    /// about it — route, conversion, metadata pass — is carried over intact.
    func testARedirectedPlanWritesToTheNewPath() throws {
        let engine = try makeEngine()
        let input = try staged("sample", "png")
        let plan = try engine.plan(input, settings: settings())
        let elsewhere = plan.destination.deletingLastPathComponent()
            .appendingPathComponent("sample.min 2.png")

        let result = try engine.shrink(plan.writing(to: elsewhere))

        XCTAssertEqual(result.output.lastPathComponent, "sample.min 2.png")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: plan.destination.path),
            "redirecting must not also write the original destination"
        )
    }

    /// The convenience overload is what keeps the 22 existing engine call sites
    /// and the whole CLI compiling untouched. It cannot prove behaviour
    /// preservation — it is *defined* as `shrink(plan(input, settings:))`, so
    /// comparing it against planning-then-executing would compare it with its
    /// own definition. What this asserts instead is that it genuinely does the
    /// work, against values fixed independently of the engine: a real file at
    /// the suffixed destination, beside its original, actually smaller than it
    /// started. A non-delegating re-implementation that dropped the suffix,
    /// wrote to the wrong directory, or wrote nothing at all fails here.
    func testTheConvenienceOverloadShrinksToTheSuffixedDestination() throws {
        let engine = try makeEngine()
        let file = try staged("sample", "png")

        let result = try engine.shrink(file, settings: settings())

        XCTAssertEqual(result.input.path, file.path)
        XCTAssertEqual(result.output.lastPathComponent, "sample.min.png")
        XCTAssertEqual(
            result.output.deletingLastPathComponent().path,
            file.deletingLastPathComponent().path,
            "the copy belongs beside its original"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.output.path))
        XCTAssertLessThan(
            result.shrunkBytes, result.originalBytes,
            "the sample fixture is expected to actually shrink"
        )
    }
}

// MARK: - Which collisions are which

final class OverwriteScanTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func touch(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    func testAPlanWhoseDestinationIsItsOwnInputIsAnOriginalAtRisk() throws {
        let file = try touch("photo.png")
        let plans = [ShrinkPlan.stub(input: file, destination: file)]

        let (originals, existing) = OverwriteScan.classify(plans)

        XCTAssertEqual(originals.map(\.input.path), [file.path])
        XCTAssertTrue(existing.isEmpty)
    }

    /// Not an original — something else is simply already sitting there.
    /// The sheet must not claim to know what it is.
    func testAnOccupiedDestinationThatIsNotTheInputIsTheOtherCategory() throws {
        let file = try touch("photo.png")
        let occupied = try touch("photo.min.png")
        let plans = [ShrinkPlan.stub(input: file, destination: occupied)]

        let (originals, existing) = OverwriteScan.classify(plans)

        XCTAssertTrue(originals.isEmpty)
        XCTAssertEqual(existing.map(\.destination.path), [occupied.path])
    }

    func testAFreeDestinationIsNoCollisionAtAll() throws {
        let file = try touch("photo.png")
        let free = root.appendingPathComponent("photo.min.png")
        let plans = [ShrinkPlan.stub(input: file, destination: free)]

        let (originals, existing) = OverwriteScan.classify(plans)

        XCTAssertTrue(originals.isEmpty)
        XCTAssertTrue(existing.isEmpty)
    }

    /// "Replace originals" plus a chosen save folder: the original is not at
    /// risk, so this belongs in the second category however destructive it is.
    func testReplacingIntoAChosenFolderIsNotAnOriginalAtRisk() throws {
        let file = try touch("photo.png")
        let dest = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let occupied = dest.appendingPathComponent("photo.png")
        try Data("y".utf8).write(to: occupied)

        let (originals, existing) = OverwriteScan.classify(
            [ShrinkPlan.stub(input: file, destination: occupied)]
        )

        XCTAssertTrue(originals.isEmpty, "the input file itself is not the destination")
        XCTAssertEqual(existing.count, 1)
    }

    /// Path equality has to survive the forms the same file can be spelled
    /// in, or an in-place plan would be misfiled as "some other file".
    func testClassificationIsNotFooledByAnUnstandardisedPath() throws {
        let file = try touch("photo.png")
        let awkward = root.appendingPathComponent("./photo.png")

        let (originals, _) = OverwriteScan.classify(
            [ShrinkPlan.stub(input: file, destination: awkward)]
        )

        XCTAssertEqual(originals.count, 1, "same file, different spelling")
    }

    func testAMixedBatchSplitsIntoBothCategories() throws {
        let inPlace = try touch("a.png")
        let other = try touch("b.png")
        let occupied = try touch("b.min.png")
        let clean = try touch("c.png")

        let (originals, existing) = OverwriteScan.classify([
            ShrinkPlan.stub(input: inPlace, destination: inPlace),
            ShrinkPlan.stub(input: other, destination: occupied),
            ShrinkPlan.stub(input: clean, destination: root.appendingPathComponent("c.min.png")),
        ])

        XCTAssertEqual(originals.count, 1)
        XCTAssertEqual(existing.count, 1)
    }
}

// MARK: - The sheet's own words

final class OverwriteRequestCopyTests: XCTestCase {

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    func testOneOriginalIsNamedAndTheWarningIsUnambiguous() {
        let request = OverwriteRequest(
            category: .original, paths: [url("photo.jpg")], unaffectedCount: 48
        )

        XCTAssertEqual(request.title, "Replace 1 original in “tmp”?")
        XCTAssertTrue(request.message.contains("photo.jpg"))
        XCTAssertTrue(request.message.contains("cannot be recovered"))
        XCTAssertTrue(request.message.contains("48"))
        XCTAssertEqual(request.skipButtonTitle, "Skip This")
    }

    func testSeveralOriginalsPluraliseTitleAndButton() {
        let request = OverwriteRequest(
            category: .original,
            paths: [url("a.jpg"), url("b.jpg"), url("c.jpg")],
            unaffectedCount: 0
        )

        XCTAssertEqual(request.title, "Replace 3 originals in “tmp”?")
        XCTAssertEqual(request.skipButtonTitle, "Skip These")
    }

    /// The correction that matters: this sheet must not describe the file as
    /// an earlier .min copy, because with a chosen save folder it may be an
    /// unrelated file that merely shares a name.
    func testTheSecondCategoryDoesNotClaimToKnowWhatTheFileIs() {
        let request = OverwriteRequest(
            category: .existingFile, paths: [url("logo.png")], unaffectedCount: 2
        )

        XCTAssertTrue(request.message.contains("logo.png"))
        XCTAssertFalse(
            request.message.lowercased().contains("earlier run"),
            "the app cannot know that, and guessing wrong about what it destroys is worse than naming the path"
        )
        XCTAssertFalse(request.message.lowercased().contains(".min copy"))
    }

    /// Files that all sit in one folder: the folder is named once, in the
    /// title, and the message lists bare filenames beneath it.
    func testFilesSharingAFolderNameItInTheTitleAndListBareNames() {
        let request = OverwriteRequest(
            category: .existingFile,
            paths: [
                URL(fileURLWithPath: "/Users/me/Shoot/minified/a.png"),
                URL(fileURLWithPath: "/Users/me/Shoot/minified/b.png"),
            ],
            unaffectedCount: 0
        )

        XCTAssertEqual(request.title, "Replace 2 files in “minified”?")
        XCTAssertTrue(request.message.contains("a.png, b.png"), request.message)
        XCTAssertFalse(request.message.contains("/Users"), "the folder is already in the title")
    }

    /// A tree of same-named files. Bare filenames would read
    /// "photo.png, photo.png" — a list that names nothing — so each is shown
    /// by the part of its path that tells it apart.
    func testSameNamedFilesInDifferentFoldersAreToldApart() {
        let request = OverwriteRequest(
            category: .original,
            paths: [
                URL(fileURLWithPath: "/Users/me/Shoot/day1/photo.png"),
                URL(fileURLWithPath: "/Users/me/Shoot/day2/photo.png"),
                URL(fileURLWithPath: "/Users/me/Shoot/day2/raw/photo.png"),
            ],
            unaffectedCount: 0
        )

        XCTAssertEqual(request.title, "Replace 3 originals?", "no single folder to name")
        XCTAssertTrue(
            request.message.contains("day1/photo.png, day2/photo.png, day2/raw/photo.png"),
            request.message
        )
    }

    /// Nothing shared but the root: a relative path would be meaningless, so
    /// the full path is shown.
    func testPathsSharingOnlyTheRootAreShownInFull() {
        let request = OverwriteRequest(
            category: .existingFile,
            paths: [URL(fileURLWithPath: "/Volumes/A/photo.png"), URL(fileURLWithPath: "/Users/me/photo.png")],
            unaffectedCount: 0
        )

        XCTAssertTrue(request.message.contains("/Volumes/A/photo.png, /Users/me/photo.png"), request.message)
    }

    /// An alert is not a scrolling list. A long drop names the first few and
    /// counts the rest, while the title still counts every file.
    func testALongListIsTruncatedWithACountOfTheRest() {
        let paths = (1...8).map { URL(fileURLWithPath: "/tmp/shoot/\($0).png") }
        let request = OverwriteRequest(category: .existingFile, paths: paths, unaffectedCount: 0)

        XCTAssertEqual(request.title, "Replace 8 files in “shoot”?")
        XCTAssertTrue(
            request.message.contains("1.png, 2.png, 3.png, 4.png, 5.png, …and 3 more"),
            request.message
        )
        XCTAssertFalse(request.message.contains("6.png"))
    }

    func testAListAtTheLimitIsNotTruncated() {
        let paths = (1...OverwriteRequest.listedNameLimit).map { URL(fileURLWithPath: "/tmp/shoot/\($0).png") }
        let request = OverwriteRequest(category: .existingFile, paths: paths, unaffectedCount: 0)

        XCTAssertFalse(request.message.contains("more"), request.message)
        XCTAssertTrue(request.message.contains("\(OverwriteRequest.listedNameLimit).png"))
    }

    func testAnUnaffectedCountOfZeroIsNotMentioned() {
        let request = OverwriteRequest(
            category: .original, paths: [url("only.jpg")], unaffectedCount: 0
        )

        XCTAssertFalse(
            request.message.contains("unaffected"),
            "there are no other files to reassure anyone about"
        )
    }
}

/// A plan with no real route behind it, for tests that care only about its
/// input and destination. Task 6 left `ShrinkPlan`'s routing fields
/// `internal` precisely so this can live here rather than in shipped code.
extension ShrinkPlan {
    static func stub(input: URL, destination: URL) -> ShrinkPlan {
        ShrinkPlan(
            input: input,
            destination: destination,
            compressor: NoopCompressor(),
            targetExtension: nil,
            needsMetadataPostPass: false,
            wasRotated: false,
            isSameFormat: true,
            metadataPolicy: .all
        )
    }
}

/// Never invoked — `OverwriteScan.classify` reads only `input` and
/// `destination`. It throws rather than returning quietly so that a test
/// which somehow reaches compression fails loudly instead of passing for
/// the wrong reason.
private struct NoopCompressor: Compressor {
    func compress(input: URL, output: URL) throws {
        throw ShrinkError.unsupportedFormat("stub")
    }
}
