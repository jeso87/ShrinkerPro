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
