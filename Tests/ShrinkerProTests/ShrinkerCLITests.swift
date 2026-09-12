import XCTest
@testable import ShrinkerPro

/// Runs the actual `shrinker` binary.
///
/// Everything else about the CLI is unit-tested — the parser, the exit
/// codes, the JSON shape, the help text — and none of it exercises the
/// *program*. An audit demonstrated the cost: `exit(firstFailure)` could be
/// changed to `exit(0)`, so every scripted caller would believe a folder of
/// failures had succeeded, and the entire suite stayed green. So could
/// printing a hardcoded version string, and so could breaking the Homebrew
/// helper layout that every `brew install` depends on.
///
/// The `shrinker` target is a dependency of this test target (project.yml),
/// so `xcodebuild test` builds the binary into the same products directory.
final class ShrinkerCLITests: XCTestCase {

    private struct MissingTestResource: Error {}

    /// The test bundle lives at
    /// `…/Debug/Shrinker Pro.app/Contents/PlugIns/ShrinkerProTests.xctest`,
    /// so the products directory is four levels up. A missing binary is a
    /// broken build rather than "nothing to check" — fail hard, matching the
    /// house pattern in `SVGCompressorTests`.
    private func binary() throws -> URL {
        let products = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()   // PlugIns
            .deletingLastPathComponent()   // Contents
            .deletingLastPathComponent()   // Shrinker Pro.app
            .deletingLastPathComponent()   // Debug
        let url = products.appendingPathComponent("shrinker")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            XCTFail("shrinker not built at \(url.path) — is it still a dependency of the test target?")
            throw MissingTestResource()
        }
        return url
    }

    private func repoRoot() -> URL {
        ProcessInfo.processInfo.environment["SRCROOT"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The four compressors and svgo in one directory, which is the layout
    /// the tool expects and the one the release zip ships.
    private func stagedHelpers() throws -> URL {
        let root = repoRoot()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-helpers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for helper in ["cjpeg", "pngquant", "gifsicle", "cwebp"] {
            let source = root.appendingPathComponent("vendor/compressors/\(helper)")
            guard FileManager.default.isExecutableFile(atPath: source.path) else {
                XCTFail("\(helper) not built — run scripts/build-compressors.sh")
                throw MissingTestResource()
            }
            try FileManager.default.copyItem(at: source, to: dir.appendingPathComponent(helper))
        }
        let svgo = root.appendingPathComponent("Sources/ShrinkerPro/Resources/svgo.jsc.js")
        guard FileManager.default.isReadableFile(atPath: svgo.path) else {
            XCTFail("svgo.jsc.js missing — run scripts/prepare-svgo.sh")
            throw MissingTestResource()
        }
        try FileManager.default.copyItem(at: svgo, to: dir.appendingPathComponent("svgo.jsc.js"))
        return dir
    }

    private struct Run {
        let stdout: String
        let stderr: String
        let code: Int32
    }

    @discardableResult
    private func run(
        _ arguments: [String], helpers: URL?, extraEnvironment: [String: String] = [:]
    ) throws -> Run {
        let process = Process()
        process.executableURL = try binary()
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        if let helpers { environment["SHRINKER_HELPERS"] = helpers.path }
        environment.merge(extraEnvironment) { _, new in new }
        process.environment = environment

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Drained before waiting: a full pipe buffer would deadlock, the same
        // reason ProcessRunner drains stderr first.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Run(
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            code: process.terminationStatus
        )
    }

    private func workspace() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-work-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func fixture(_ name: String, _ ext: String, into dir: URL) throws -> URL {
        let source = repoRoot().appendingPathComponent("Tests/ShrinkerProTests/Fixtures/\(name).\(ext)")
        let staged = dir.appendingPathComponent("\(name).\(ext)")
        try FileManager.default.copyItem(at: source, to: staged)
        return staged
    }

    // MARK: - The binary reports itself honestly

    /// Pins what the *binary prints*, not the constant.
    /// `testTheCLIVersionMatchesTheProjectsMarketingVersion` compares
    /// `ShrinkerVersion.current` against project.yml; nothing checked that
    /// `--version` actually prints it.
    func testVersionPrintsTheSharedConstant() throws {
        let result = try run(["--version"], helpers: nil)

        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), ShrinkerVersion.current)
    }

    // MARK: - Exit codes, as actually emitted

    func testASuccessfulRunExitsZero() throws {
        let helpers = try stagedHelpers()
        let work = try workspace()
        let input = try fixture("sample", "png", into: work)

        let result = try run(["--out", work.appendingPathComponent("out").path, input.path], helpers: helpers)

        XCTAssertEqual(result.code, 0, result.stderr)
    }

    /// The mutation the audit found: `exit(firstFailure)` → `exit(0)` leaves
    /// the whole suite green while every scripted caller believes a folder of
    /// failures succeeded. One good file and one bad one must still fail.
    func testABatchContainingAFailureExitsNonZero() throws {
        let helpers = try stagedHelpers()
        let work = try workspace()
        let good = try fixture("sample", "png", into: work)
        let bad = work.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: bad)

        let result = try run(
            ["--out", work.appendingPathComponent("out").path, good.path, bad.path], helpers: helpers
        )

        XCTAssertNotEqual(result.code, 0, "a batch with a failure in it must not report success")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: work.appendingPathComponent("out/sample.min.png").path
            ),
            "the good file should still have been written"
        )
    }

    /// A path that does not exist is a mistake worth naming. Silently
    /// ignoring it and exiting 0 tells an agent its typo succeeded.
    func testANonexistentPathIsReportedRatherThanIgnored() throws {
        let helpers = try stagedHelpers()
        let work = try workspace()
        let good = try fixture("sample", "png", into: work)
        let missing = work.appendingPathComponent("no-such-file.png").path

        let result = try run(
            ["--out", work.appendingPathComponent("out").path, good.path, missing], helpers: helpers
        )

        XCTAssertNotEqual(result.code, 0, "a path that does not exist must not be a silent success")
        XCTAssertTrue(
            result.stderr.contains("no-such-file.png"),
            "the message must name the path that was not found, got: \(result.stderr)"
        )
    }

    // MARK: - Saying what actually happened

    /// The summary branches on `savedPercent > 0`, but a conversion that
    /// grows has a *negative* saving — so a written, larger file is announced
    /// as "left alone". The declined case is distinguishable by the output
    /// path equalling the input; that is what the branch should test.
    func testAConversionThatGrowsIsNotDescribedAsLeftAlone() throws {
        let helpers = try stagedHelpers()
        let work = try workspace()
        let input = try fixture("sample", "jpg", into: work)
        let out = work.appendingPathComponent("out")

        let result = try run(["--to", "png", "--out", out.path, input.path], helpers: helpers)

        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: out.appendingPathComponent("sample.min.png").path),
            "the conversion should have been written"
        )
        XCTAssertFalse(
            result.stdout.contains("left alone"),
            "a file that was written must not be reported as untouched, got: \(result.stdout)"
        )
    }

    /// `--in-place` and `--out` mean incompatible things. Accepting both
    /// silently produces a third behaviour — writing into the out directory
    /// with no `.min` suffix, leaving the original alone — which is neither
    /// flag's documented meaning.
    func testInPlaceAndOutTogetherAreRejected() throws {
        let helpers = try stagedHelpers()
        let work = try workspace()
        let input = try fixture("sample", "png", into: work)

        let result = try run(
            ["--in-place", "--out", work.appendingPathComponent("out").path, input.path],
            helpers: helpers
        )

        XCTAssertEqual(result.code, 64, "contradictory flags are a usage error")
        XCTAssertTrue(
            result.stderr.contains("--in-place") && result.stderr.contains("--out"),
            "the message must name both flags, got: \(result.stderr)"
        )
    }

    // MARK: - Finding its own helpers

    /// The Homebrew layout, which nothing has ever exercised: the binary in
    /// `bin/`, helpers in `../libexec/shrinker/`, and no `SHRINKER_HELPERS`
    /// set. Dropping the `deletingLastPathComponent()` from that lookup would
    /// break every `brew install` while the zip layout kept working, so local
    /// testing would never notice.
    func testHelpersAreFoundViaTheHomebrewLibexecLayout() throws {
        let staged = try stagedHelpers()
        let root = try workspace()
        let bin = root.appendingPathComponent("bin")
        let libexec = root.appendingPathComponent("libexec/shrinker")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: libexec.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: staged, to: libexec)
        try FileManager.default.copyItem(at: try binary(), to: bin.appendingPathComponent("shrinker"))

        let work = try workspace()
        let input = try fixture("sample", "png", into: work)

        let process = Process()
        process.executableURL = bin.appendingPathComponent("shrinker")
        process.arguments = ["--out", work.appendingPathComponent("out").path, input.path]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "SHRINKER_HELPERS")
        process.environment = environment
        let err = Pipe()
        process.standardOutput = Pipe()
        process.standardError = err
        try process.run()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        XCTAssertEqual(
            process.terminationStatus, 0,
            "the libexec layout must work without SHRINKER_HELPERS: \(String(decoding: errData, as: UTF8.self))"
        )
    }
}
