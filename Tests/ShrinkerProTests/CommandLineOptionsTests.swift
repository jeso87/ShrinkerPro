import XCTest
@testable import ShrinkerPro

/// Argument parsing for the `shrinker` CLI.
///
/// It lives in `Core/` rather than beside the tool's `main.swift` because it
/// is a pure argv-to-options transformation with no IO — which means the
/// existing test target covers it without the CLI needing a test target of
/// its own, and every flag can be asserted without spawning a process.
final class CommandLineOptionsTests: XCTestCase {

    // MARK: - Inputs

    func testBarePathsAreCollectedAsInputs() throws {
        let options = try CommandLineOptions.parse(["a.png", "b/c.jpg"])
        XCTAssertEqual(options.inputs, ["a.png", "b/c.jpg"])
    }

    func testNoArgumentsIsARequestForHelpRatherThanAnError() throws {
        // A bare `shrinker` should explain itself, not fail. For an agent
        // discovering the tool, the no-argument invocation is the first
        // thing it will try.
        let options = try CommandLineOptions.parse([])
        XCTAssertTrue(options.showsHelp)
        XCTAssertTrue(options.inputs.isEmpty)
    }

    // MARK: - The destructive default

    /// The safety-critical property of the whole tool. `ShrinkEngine` resolves
    /// the output path *to the input path* when `keepOriginal` is false — it
    /// overwrites the user's file in place. An agent that shells out to this
    /// without reading the flags must not destroy originals by accident, so
    /// the default has to match the app's: write alongside with `.min`.
    func testTheDefaultIsNonDestructive() throws {
        let options = try CommandLineOptions.parse(["a.png"])
        XCTAssertFalse(
            options.inPlace,
            "overwriting originals must never be the default — it has to be asked for"
        )
    }

    func testInPlaceIsOptedIntoExplicitly() throws {
        let options = try CommandLineOptions.parse(["--in-place", "a.png"])
        XCTAssertTrue(options.inPlace)
        XCTAssertEqual(options.inputs, ["a.png"])
    }

    // MARK: - Output shape

    func testJSONIsOffByDefaultAndOptIn() throws {
        XCTAssertFalse(try CommandLineOptions.parse(["a.png"]).json)
        XCTAssertTrue(try CommandLineOptions.parse(["--json", "a.png"]).json)
    }

    // MARK: - Flag handling

    func testFlagsMayFollowTheirInputs() throws {
        // Agents compose command lines in whatever order they think of the
        // parts; order-dependence would be a gratuitous failure mode.
        let options = try CommandLineOptions.parse(["a.png", "--json"])
        XCTAssertTrue(options.json)
        XCTAssertEqual(options.inputs, ["a.png"])
    }

    func testAnUnknownFlagIsRejectedRatherThanTreatedAsAPath() throws {
        // Silently treating `--dry-run` as a filename would report "no such
        // file" for a flag the user believed existed — the failure would name
        // the wrong thing entirely.
        XCTAssertThrowsError(try CommandLineOptions.parse(["--dry-run", "a.png"])) { error in
            XCTAssertEqual(error as? CommandLineParseError, .unknownFlag("--dry-run"))
        }
    }

    func testAFlagExpectingAValueSaysSoWhenItIsMissing() throws {
        XCTAssertThrowsError(try CommandLineOptions.parse(["a.png", "--out"])) { error in
            XCTAssertEqual(error as? CommandLineParseError, .missingValue("--out"))
        }
    }

    /// `--` ends flag parsing, so a file genuinely named `--json` is still
    /// reachable. Cheap to support and impossible to add later without
    /// changing the meaning of existing command lines.
    func testDoubleDashEndsFlagParsing() throws {
        let options = try CommandLineOptions.parse(["--", "--json"])
        XCTAssertEqual(options.inputs, ["--json"])
        XCTAssertFalse(options.json)
    }

    // MARK: - Quality

    func testQualityDefaultsToStandard() throws {
        XCTAssertEqual(try CommandLineOptions.parse(["a.png"]).quality, .level(.standard))
    }

    func testQualityAcceptsALevelName() throws {
        XCTAssertEqual(
            try CommandLineOptions.parse(["--quality", "high", "a.png"]).quality,
            .level(.high)
        )
    }

    /// Nobody types Swift's camelCase at a shell prompt, and an agent
    /// reading `--help` shouldn't have to guess it either. Names match
    /// case-insensitively, and Super Low takes a hyphen the way a person
    /// would write it.
    func testQualityLevelNamesAreForgiving() throws {
        XCTAssertEqual(try CommandLineOptions.parse(["--quality", "HIGH", "a.png"]).quality, .level(.high))
        XCTAssertEqual(try CommandLineOptions.parse(["--quality", "Low", "a.png"]).quality, .level(.low))
        XCTAssertEqual(try CommandLineOptions.parse(["--quality", "super-low", "a.png"]).quality, .level(.superLow))
        XCTAssertEqual(try CommandLineOptions.parse(["--quality", "superlow", "a.png"]).quality, .level(.superLow))
    }

    /// The reason this flag is not simply a `QualityLevel`: an agent asked to
    /// hit a size target needs to sweep values, and three named stops give it
    /// three tries and nowhere to go.
    func testQualityAcceptsANumber() throws {
        XCTAssertEqual(try CommandLineOptions.parse(["--quality", "85", "a.png"]).quality, .numeric(85))
        XCTAssertEqual(try CommandLineOptions.parse(["--quality", "0", "a.png"]).quality, .numeric(0))
        XCTAssertEqual(try CommandLineOptions.parse(["--quality", "100", "a.png"]).quality, .numeric(100))
    }

    func testQualityRejectsNumbersOutsideTheEncoderRange() throws {
        for value in ["101", "-1", "1000"] {
            XCTAssertThrowsError(try CommandLineOptions.parse(["--quality", value, "a.png"]), value) { error in
                XCTAssertEqual(error as? CommandLineParseError, .invalidValue(flag: "--quality", value: value))
            }
        }
    }

    func testQualityRejectsAValueThatIsNeitherLevelNorNumber() throws {
        XCTAssertThrowsError(try CommandLineOptions.parse(["--quality", "medium", "a.png"])) { error in
            XCTAssertEqual(error as? CommandLineParseError, .invalidValue(flag: "--quality", value: "medium"))
        }
    }

    func testQualityNeedsAValue() throws {
        XCTAssertThrowsError(try CommandLineOptions.parse(["a.png", "--quality"])) { error in
            XCTAssertEqual(error as? CommandLineParseError, .missingValue("--quality"))
        }
    }

    // MARK: - Conversion target

    /// No `--to` means every file keeps its own format. The CLI has no
    /// stored per-format rules to fall back on — those live in the app's
    /// preferences, which a headless run deliberately never reads — so the
    /// absence of this flag is the absence of any conversion.
    func testNoConversionTargetByDefault() throws {
        XCTAssertNil(try CommandLineOptions.parse(["a.png"]).convertTo)
    }

    func testConversionTargetAcceptsEachFormat() throws {
        XCTAssertEqual(try CommandLineOptions.parse(["--to", "webp", "a.png"]).convertTo, .webp)
        XCTAssertEqual(try CommandLineOptions.parse(["--to", "avif", "a.png"]).convertTo, .avif)
        XCTAssertEqual(try CommandLineOptions.parse(["--to", "png", "a.png"]).convertTo, .png)
        XCTAssertEqual(try CommandLineOptions.parse(["--to", "JPEG", "a.png"]).convertTo, .jpeg)
    }

    /// "jpg" is what people and agents actually write. Refusing it because
    /// the enum happens to spell the case `jpeg` would be a gratuitous
    /// failure on the single most common image format.
    func testJPGIsAcceptedAsJPEG() throws {
        XCTAssertEqual(try CommandLineOptions.parse(["--to", "jpg", "a.png"]).convertTo, .jpeg)
    }

    func testAnUnknownConversionTargetIsRejected() throws {
        XCTAssertThrowsError(try CommandLineOptions.parse(["--to", "tiff", "a.png"])) { error in
            XCTAssertEqual(error as? CommandLineParseError, .invalidValue(flag: "--to", value: "tiff"))
        }
    }

    func testConversionTargetNeedsAValue() throws {
        XCTAssertThrowsError(try CommandLineOptions.parse(["a.png", "--to"])) { error in
            XCTAssertEqual(error as? CommandLineParseError, .missingValue("--to"))
        }
    }

    // MARK: - Metadata

    func testMetadataDefaultsToKeepingEverything() throws {
        XCTAssertEqual(try CommandLineOptions.parse(["a.png"]).metadata, .all)
    }

    /// The spelling trap. `MetadataPolicy.stripped` carries the rawValue
    /// `"none"` — it is named `stripped` in Swift only to avoid colliding
    /// with `Optional.none` at call sites that rely on inference. "none" is
    /// both the stored value and the word a person would reach for, so it is
    /// the spelling the flag must accept.
    func testMetadataAcceptsEachPolicyByItsStoredSpelling() throws {
        XCTAssertEqual(try CommandLineOptions.parse(["--metadata", "all", "a.png"]).metadata, .all)
        XCTAssertEqual(try CommandLineOptions.parse(["--metadata", "copyright", "a.png"]).metadata, .copyright)
        XCTAssertEqual(try CommandLineOptions.parse(["--metadata", "none", "a.png"]).metadata, .stripped)
        XCTAssertEqual(try CommandLineOptions.parse(["--metadata", "NONE", "a.png"]).metadata, .stripped)
    }

    func testAnUnknownMetadataPolicyIsRejected() throws {
        XCTAssertThrowsError(try CommandLineOptions.parse(["--metadata", "exif", "a.png"])) { error in
            XCTAssertEqual(error as? CommandLineParseError, .invalidValue(flag: "--metadata", value: "exif"))
        }
    }

    func testMetadataNeedsAValue() throws {
        XCTAssertThrowsError(try CommandLineOptions.parse(["a.png", "--metadata"])) { error in
            XCTAssertEqual(error as? CommandLineParseError, .missingValue("--metadata"))
        }
    }

    // MARK: - Resolving a choice to encoder numbers

    func testALevelChoiceResolvesToThatLevelsSettings() {
        XCTAssertEqual(QualityChoice.level(.high).settings, QualityLevel.high.settings)
        XCTAssertEqual(QualityChoice.level(.superLow).settings, QualityLevel.superLow.settings)
    }

    /// A number is taken literally on every axis, including cjpeg's — where
    /// `.standard` deliberately passes nothing at all. Someone who writes
    /// `--quality 75` has asked for an explicit 75, which is genuinely not
    /// the same bytes as omitting the flag (see `QualitySettings`), and
    /// honouring the request beats silently second-guessing it.
    func testANumericChoiceIsTakenLiterallyOnEveryAxis() {
        let resolved = QualityChoice.numeric(85).settings

        XCTAssertEqual(resolved.unitScale, 0.85, accuracy: 0.0001)
        XCTAssertEqual(resolved.cwebpScale, 85)
        XCTAssertEqual(resolved.cjpegQuality, 85)
    }

    // MARK: - Becoming the engine's OutputSettings

    /// With no flags at all, a headless run must behave like the app's own
    /// defaults: write a `.min` copy beside each original, touching nothing.
    func testDefaultOptionsProduceNonDestructiveSettingsBesideTheInput() throws {
        let settings = try CommandLineOptions.parse(["a.png"]).outputSettings

        XCTAssertTrue(settings.saveInSameFolder)
        XCTAssertNil(settings.savePath)
        XCTAssertTrue(settings.keepOriginal, "the CLI must not overwrite originals unless asked")
        XCTAssertFalse(settings.useSubfolder, "there is no --subfolder flag; the CLI writes where it is told")
    }

    func testInPlaceClearsKeepOriginal() throws {
        let settings = try CommandLineOptions.parse(["--in-place", "a.png"]).outputSettings
        XCTAssertFalse(settings.keepOriginal)
    }

    func testOutRedirectsTheDestination() throws {
        let settings = try CommandLineOptions.parse(["--out", "/tmp/shrunk", "a.png"]).outputSettings

        XCTAssertFalse(settings.saveInSameFolder, "a redirected destination is not 'same folder'")
        XCTAssertEqual(settings.savePath?.path, "/tmp/shrunk")
    }

    /// `--to` becomes the session override rather than a conversion rule.
    /// It is the only field that can express a PNG target, and it is what
    /// overrides every format at once — which is exactly what the flag says.
    func testConversionTargetBecomesTheSessionOverride() throws {
        let settings = try CommandLineOptions.parse(["--to", "webp", "a.png"]).outputSettings
        XCTAssertEqual(settings.sessionFormat, .webp)
    }

    /// A headless run reads no preferences, so there are no stored rules to
    /// carry. Everything stays "keep" and conversion happens only via --to.
    func testNoStoredConversionRulesAreInvented() throws {
        let settings = try CommandLineOptions.parse(["a.png"]).outputSettings

        XCTAssertNil(settings.sessionFormat)
        XCTAssertEqual(settings.conversionRules.png, .keep)
        XCTAssertEqual(settings.conversionRules.jpeg, .keep)
        XCTAssertEqual(settings.conversionRules.webp, .keep)
        XCTAssertEqual(settings.conversionRules.avif, .keep)
    }

    func testMetadataPolicyIsCarried() throws {
        let settings = try CommandLineOptions.parse(["--metadata", "none", "a.png"]).outputSettings
        XCTAssertEqual(settings.metadataPolicy, .stripped)
    }

    /// The reason `OutputSettings` has to carry resolved encoder numbers
    /// rather than a `QualityLevel`: there is no level that means 85, and
    /// inventing one would put a value in the Settings picker that no user
    /// chose.
    func testANumericQualityReachesTheSettingsAsResolvedNumbers() throws {
        let settings = try CommandLineOptions.parse(["--quality", "85", "a.png"]).outputSettings

        XCTAssertEqual(settings.quality.unitScale, 0.85, accuracy: 0.0001)
        XCTAssertEqual(settings.quality.cwebpScale, 85)
        XCTAssertEqual(settings.quality.cjpegQuality, 85)
    }

    func testANamedQualityResolvesToThatLevelsNumbers() throws {
        let settings = try CommandLineOptions.parse(["--quality", "super-low", "a.png"]).outputSettings
        XCTAssertEqual(settings.quality, QualityLevel.superLow.settings)
    }

    // MARK: - JSON output

    private func encodedReport(
        input: String = "/photos/a.png",
        output: String = "/photos/a.min.png",
        originalBytes: Int = 1000,
        shrunkBytes: Int = 250
    ) throws -> [String: Any] {
        let result = ShrinkResult(
            input: URL(fileURLWithPath: input),
            output: URL(fileURLWithPath: output),
            originalBytes: originalBytes,
            shrunkBytes: shrunkBytes
        )
        let data = try JSONEncoder().encode(ShrinkReport(result))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// `URL` encodes as `file:///photos/a.png` by default, which is useless
    /// to a caller that wants to hand the path to another command. Plain
    /// filesystem paths are the only form worth emitting.
    func testReportEmitsPlainPathsNotFileURLs() throws {
        let json = try encodedReport()

        XCTAssertEqual(json["input"] as? String, "/photos/a.png")
        XCTAssertEqual(json["output"] as? String, "/photos/a.min.png")
    }

    /// `savedPercent` is a computed property on `ShrinkResult`, so it does
    /// not synthesize into an encoding at all — and it is the single number
    /// a caller is most likely to want. Stating it explicitly is the whole
    /// reason this report type exists rather than conforming the engine's
    /// result to Codable.
    func testReportCarriesTheComputedSaving() throws {
        let json = try encodedReport(originalBytes: 1000, shrunkBytes: 250)

        XCTAssertEqual(json["originalBytes"] as? Int, 1000)
        XCTAssertEqual(json["shrunkBytes"] as? Int, 250)
        XCTAssertEqual(json["savedPercent"] as? Int, 75)
    }

    /// A declined re-encode reports the original, unchanged, at 0% — and
    /// that has to survive into JSON as a real result rather than looking
    /// like a failure, because nothing went wrong.
    func testReportRepresentsADeclinedShrinkAsZeroSaved() throws {
        let json = try encodedReport(
            input: "/photos/a.webp", output: "/photos/a.webp",
            originalBytes: 18828, shrunkBytes: 18828
        )

        XCTAssertEqual(json["savedPercent"] as? Int, 0)
        XCTAssertEqual(json["output"] as? String, "/photos/a.webp")
    }

    // MARK: - Help text

    /// `--help` is the only discovery surface an agent has. A flag the
    /// parser accepts but help never mentions is effectively invisible, and
    /// that drift is the whole reason this is asserted mechanically rather
    /// than by reading the string once and trusting it.
    func testHelpNamesEveryFlagTheParserAccepts() {
        let help = CommandLineOptions.helpText

        for flag in ["--quality", "--to", "--metadata", "--out", "--in-place", "--json", "--help", "--version"] {
            XCTAssertTrue(help.contains(flag), "--help never mentions \(flag)")
        }
    }

    /// Every level name has to appear, or an agent has no way to learn that
    /// "super-low" is spelled with a hyphen — and it would reasonably guess
    /// the Swift spelling, which is the one thing that looks wrong.
    func testHelpNamesEveryQualityLevel() {
        let help = CommandLineOptions.helpText
        for name in ["super-low", "low", "standard", "high"] {
            XCTAssertTrue(help.contains(name), "--help never mentions the \(name) level")
        }
    }

    /// The single most consequential thing a reader can misunderstand: that
    /// this writes a copy by default and only overwrites when asked.
    func testHelpStatesThatOriginalsAreKeptByDefault() {
        XCTAssertTrue(
            CommandLineOptions.helpText.lowercased().contains(".min"),
            "--help must say where output goes when --in-place is absent"
        )
    }

    // MARK: - Exit codes

    /// Scripts and agents branch on these, so they are a compatibility
    /// surface: pinned here so changing one has to be deliberate.
    func testEachFailureHasItsOwnStableExitCode() {
        XCTAssertEqual(ShrinkError.unsupportedFormat("txt").exitCode, 2)
        XCTAssertEqual(ShrinkError.helperMissing("cjpeg").exitCode, 3)
        XCTAssertEqual(ShrinkError.compressorFailed(tool: "cjpeg", code: 1, message: "").exitCode, 4)
        XCTAssertEqual(ShrinkError.javascriptFailed("").exitCode, 5)
        XCTAssertEqual(ShrinkError.outputNotWritten(URL(fileURLWithPath: "/a")).exitCode, 6)
        XCTAssertEqual(ShrinkError.conversionFailed("").exitCode, 7)
    }

    /// Nothing may collide with 0, and nothing may collide with anything
    /// else — an exit code that two different failures share tells a caller
    /// nothing it could act on.
    func testExitCodesAreDistinctAndNonZero() {
        let codes = [
            ShrinkError.unsupportedFormat("txt").exitCode,
            ShrinkError.helperMissing("cjpeg").exitCode,
            ShrinkError.compressorFailed(tool: "cjpeg", code: 1, message: "").exitCode,
            ShrinkError.javascriptFailed("").exitCode,
            ShrinkError.outputNotWritten(URL(fileURLWithPath: "/a")).exitCode,
            ShrinkError.conversionFailed("").exitCode,
        ]

        XCTAssertEqual(Set(codes).count, codes.count, "two failures share an exit code")
        XCTAssertFalse(codes.contains(0), "0 means success and cannot also mean a failure")
    }

    /// Bad usage is distinct from a failed shrink: one means "you typed it
    /// wrong", the other "the work itself failed", and a caller retrying the
    /// same command line needs to tell those apart.
    func testUsageErrorsHaveTheirOwnExitCode() {
        XCTAssertEqual(CommandLineParseError.unknownFlag("--nope").exitCode, 64)
        XCTAssertEqual(CommandLineParseError.missingValue("--out").exitCode, 64)
        XCTAssertEqual(CommandLineParseError.invalidValue(flag: "--to", value: "tiff").exitCode, 64)
    }

    // MARK: - Self-description

    func testHelpAndVersionAreRecognised() throws {
        XCTAssertTrue(try CommandLineOptions.parse(["--help"]).showsHelp)
        XCTAssertTrue(try CommandLineOptions.parse(["-h"]).showsHelp)
        XCTAssertTrue(try CommandLineOptions.parse(["--version"]).showsVersion)
    }
}
