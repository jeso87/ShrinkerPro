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

    /// The convenience overload is what keeps 22 existing engine tests and
    /// the entire CLI compiling. It must agree with planning then executing.
    func testTheConvenienceOverloadMatchesPlanThenShrink() throws {
        let engine = try makeEngine()
        let a = try staged("sample", "png")
        let b = try staged("sample", "png")

        let direct = try engine.shrink(a, settings: settings())
        let viaPlan = try engine.shrink(engine.plan(b, settings: settings()))

        XCTAssertEqual(direct.output.lastPathComponent, viaPlan.output.lastPathComponent)
        XCTAssertEqual(direct.shrunkBytes, viaPlan.shrunkBytes)
    }
}
