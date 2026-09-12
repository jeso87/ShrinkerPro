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

    // MARK: - Self-description

    func testHelpAndVersionAreRecognised() throws {
        XCTAssertTrue(try CommandLineOptions.parse(["--help"]).showsHelp)
        XCTAssertTrue(try CommandLineOptions.parse(["-h"]).showsHelp)
        XCTAssertTrue(try CommandLineOptions.parse(["--version"]).showsVersion)
    }
}
