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

    // MARK: - Self-description

    func testHelpAndVersionAreRecognised() throws {
        XCTAssertTrue(try CommandLineOptions.parse(["--help"]).showsHelp)
        XCTAssertTrue(try CommandLineOptions.parse(["-h"]).showsHelp)
        XCTAssertTrue(try CommandLineOptions.parse(["--version"]).showsVersion)
    }
}
