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

    // MARK: - Refusing to lose work

    /// `--out` flattens every result into one directory, so two inputs with
    /// the same name in different folders resolve to the same output path
    /// and the second silently replaces the first. Originals are safe, but
    /// the user asked for two results and got one, with exit 0 and no
    /// mention of it.
    ///
    /// Refused rather than disambiguated: inventing `logo-1.min.png` would
    /// invent a filename nobody asked for, and picking a winner is what the
    /// bug already does.
    func testTwoInputsThatWouldOverwriteEachOtherAreRefused() throws {
        let helpers = try stagedHelpers()
        let work = try workspace()
        let a = work.appendingPathComponent("a")
        let b = work.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)

        let source = repoRoot().appendingPathComponent("Tests/ShrinkerProTests/Fixtures/sample.png")
        try FileManager.default.copyItem(at: source, to: a.appendingPathComponent("logo.png"))
        try FileManager.default.copyItem(at: source, to: b.appendingPathComponent("logo.png"))

        let out = work.appendingPathComponent("out")
        let result = try run(
            ["--out", out.path,
             a.appendingPathComponent("logo.png").path,
             b.appendingPathComponent("logo.png").path],
            helpers: helpers
        )

        XCTAssertNotEqual(result.code, 0, "one result silently replacing another must not be a success")
        XCTAssertTrue(
            result.stderr.contains("logo.png"),
            "the message must name the file that collides, got: \(result.stderr)"
        )
    }

    /// The same filename is fine when the outputs differ — a PNG and a JPEG
    /// called `logo` produce `logo.min.png` and `logo.min.jpg`, which do not
    /// collide. Refusing these would make `--out` useless on any ordinary
    /// mixed folder.
    func testSameStemWithDifferentOutputExtensionsIsAllowed() throws {
        let helpers = try stagedHelpers()
        let work = try workspace()
        let fixtures = repoRoot().appendingPathComponent("Tests/ShrinkerProTests/Fixtures")
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent("sample.png"),
            to: work.appendingPathComponent("logo.png")
        )
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent("sample.jpg"),
            to: work.appendingPathComponent("logo.jpg")
        )

        let out = work.appendingPathComponent("out")
        let result = try run(
            ["--out", out.path,
             work.appendingPathComponent("logo.png").path,
             work.appendingPathComponent("logo.jpg").path],
            helpers: helpers
        )

        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("logo.min.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("logo.min.jpg").path))
    }

    /// The case a naive basename check gets wrong in the other direction:
    /// HEIC always converts to JPEG, so `photo.heic` and `photo.jpg` both
    /// land on `photo.min.jpg` despite having different input extensions.
    func testAHEICAndAJPEGWithTheSameStemCollide() throws {
        let helpers = try stagedHelpers()
        let work = try workspace()
        let fixtures = repoRoot().appendingPathComponent("Tests/ShrinkerProTests/Fixtures")
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent("sample.heic"),
            to: work.appendingPathComponent("photo.heic")
        )
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent("sample.jpg"),
            to: work.appendingPathComponent("photo.jpg")
        )

        let result = try run(
            ["--out", work.appendingPathComponent("out").path,
             work.appendingPathComponent("photo.heic").path,
             work.appendingPathComponent("photo.jpg").path],
            helpers: helpers
        )

        XCTAssertNotEqual(
            result.code, 0,
            "HEIC becomes JPEG, so both of these resolve to photo.min.jpg"
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

    // MARK: - --if-exists

    /// The compatibility guarantee: with no flag, a re-run replaces, exactly
    /// as every earlier version did.
    func testTheDefaultStillReplacesSilently() throws {
        let helpers = try stagedHelpers()
        let work = try workspace()
        let input = try fixture("sample", "png", into: work)

        _ = try run([input.path], helpers: helpers)
        let result = try run([input.path], helpers: helpers)

        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: work.appendingPathComponent("sample.min 2.png").path),
            "the default must not start inventing names"
        )
    }

    /// The plan/decide/execute split runs the *whole* planning sweep before
    /// any file is executed, so recording each phase's failure directly into
    /// a single `firstFailure` lets a later input's planning failure outrank
    /// an earlier input's execution failure — changing the exit code for a
    /// command line that types no --if-exists flag at all. The first input
    /// here plans fine (a supported extension) but fails during execution
    /// (its content is not actually that format); the second fails during
    /// planning (an unsupported extension). The first input's code must win,
    /// exactly as it would have under the old single-loop version.
    func testAnEarlierExecutionFailureOutranksALaterPlanningFailure() throws {
        let helpers = try stagedHelpers()
        let work = try workspace()

        // A supported extension whose content is not actually a PNG: passes
        // planning (which only checks the extension and probes orientation,
        // failing closed to "upright" on unreadable content) but pngquant
        // rejects it at execution time.
        let willFailToCompress = work.appendingPathComponent("willFailToCompress.png")
        try Data("not actually a png".utf8).write(to: willFailToCompress)

        let bad = work.appendingPathComponent("bad.txt")
        try Data("hello".utf8).write(to: bad)

        let result = try run([willFailToCompress.path, bad.path], helpers: helpers)

        // Observed directly against the built binary before writing this
        // assertion: pngquant's decode failure surfaces as
        // ShrinkError.compressorFailed, which this project pins to exit 4 —
        // not bad.txt's unsupportedFormat (2), which is what the ordering
        // bug reported instead.
        XCTAssertEqual(
            result.code, 4,
            "the first input's failure must win, got code \(result.code), stderr: \(result.stderr)"
        )
    }

    func testSkipLeavesTheExistingFileAloneAndSaysSo() throws {
        let helpers = try stagedHelpers()
        let work = try workspace()
        let input = try fixture("sample", "png", into: work)

        _ = try run([input.path], helpers: helpers)
        let output = work.appendingPathComponent("sample.min.png")
        let before = try Data(contentsOf: output)

        let result = try run(["--if-exists", "skip", input.path], helpers: helpers)

        XCTAssertEqual(result.code, 0, "skipping is what was asked for, not a failure")
        XCTAssertEqual(try Data(contentsOf: output), before)
        XCTAssertTrue(
            result.stderr.contains("sample.min.png"),
            "a skipped file must be named, got: \(result.stderr)"
        )
    }

    /// A declined re-encode reports the file's real size on both sides, so
    /// `originalBytes` means "the real size of the input file" on every
    /// `--json` line a caller sees. A skipped line must mirror that
    /// convention rather than reporting 0/0, which would silently undercount
    /// any caller summing `originalBytes` to answer "how many bytes did I
    /// process" — and would read, alongside a never-written `output` path,
    /// as "a 0-byte file was written here".
    func testASkippedFilesJSONLineReportsItsRealSize() throws {
        let helpers = try stagedHelpers()
        let work = try workspace()
        let input = try fixture("sample", "png", into: work)
        let realSize = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: input.path)[.size] as? Int
        )

        _ = try run([input.path], helpers: helpers)
        let result = try run(["--if-exists", "skip", "--json", input.path], helpers: helpers)

        XCTAssertEqual(result.code, 0, result.stderr)
        let line = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = try XCTUnwrap(line.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["status"] as? String, "skipped")
        XCTAssertEqual(json["originalBytes"] as? Int, realSize, "must report the input's real size, not 0")
        XCTAssertEqual(json["shrunkBytes"] as? Int, realSize)
        XCTAssertEqual(json["savedPercent"] as? Int, 0)
    }

    /// The same file named twice plans it twice. stderr already reported the
    /// skip once per destination; the `--json` stream must not report the
    /// one skipped file as two, or a caller counting lines counts it double.
    func testASkippedFileNamedTwiceIsReportedOnceInJSON() throws {
        let helpers = try stagedHelpers()
        let work = try workspace()
        let input = try fixture("sample", "png", into: work)

        _ = try run([input.path], helpers: helpers)
        let result = try run(["--if-exists", "skip", "--json", input.path, input.path], helpers: helpers)

        XCTAssertEqual(result.code, 0, result.stderr)
        let lines = result.stdout.split(separator: "\n")
        XCTAssertEqual(lines.count, 1, "one skipped file, one line — got: \(result.stdout)")
        XCTAssertEqual(
            result.stderr.components(separatedBy: "already exists, skipped").count - 1, 1,
            "and stderr names it once too, got: \(result.stderr)"
        )
    }

    func testKeepBothWritesANumberedSibling() throws {
        let helpers = try stagedHelpers()
        let work = try workspace()
        let input = try fixture("sample", "png", into: work)

        _ = try run([input.path], helpers: helpers)
        let result = try run(["--if-exists", "keep-both", input.path], helpers: helpers)

        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.appendingPathComponent("sample.min.png").path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: work.appendingPathComponent("sample.min 2.png").path),
            "keep-both must leave both on disk"
        )
    }

    func testFailRefusesTheRunBeforeDoingAnyWork() throws {
        let helpers = try stagedHelpers()
        let work = try workspace()
        let collides = try fixture("sample", "png", into: work)
        _ = try run([collides.path], helpers: helpers)

        let fresh = work.appendingPathComponent("fresh.png")
        try FileManager.default.copyItem(at: collides, to: fresh)

        let result = try run(["--if-exists", "fail", collides.path, fresh.path], helpers: helpers)

        XCTAssertEqual(result.code, 65, "a set of inputs that cannot be honoured is EX_DATAERR")
        XCTAssertTrue(result.stderr.contains("sample.min.png"), result.stderr)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: work.appendingPathComponent("fresh.min.png").path),
            "fail must refuse before any work starts, not halfway through"
        )
    }

    /// Not a guard on anything in this file: `CommandLineOptions.parse` refuses
    /// this combination before the plan/decide/execute path in `main.swift`
    /// ever runs, so no mutation to that code can make this test fail. What it
    /// does guard end-to-end is that the parser's refusal actually reaches the
    /// binary as exit 64 with both flags named — i.e. that `main.swift`'s
    /// top-level `catch let error as CommandLineParseError` still maps this
    /// particular throw correctly, independent of anything `--if-exists` does
    /// once a run starts.
    func testInPlaceWithANonDefaultIfExistsIsRejected() throws {
        let helpers = try stagedHelpers()
        let work = try workspace()
        let input = try fixture("sample", "png", into: work)

        let result = try run(["--in-place", "--if-exists", "skip", input.path], helpers: helpers)

        XCTAssertEqual(result.code, 64, "contradictory flags are a usage error")
        XCTAssertTrue(
            result.stderr.contains("--in-place") && result.stderr.contains("--if-exists"),
            "the message must name both flags, got: \(result.stderr)"
        )
    }

    // MARK: - keep-both resolves the input-vs-input refusal

    /// Two inputs landing on one name is still refused by default — picking a
    /// winner remains the bug it always was. But with keep-both the user has
    /// explicitly asked for numbering, so inventing a name is no longer
    /// inventing: it is doing as told.
    func testKeepBothDisambiguatesTwoInputsThatWouldCollide() throws {
        let helpers = try stagedHelpers()
        let work = try workspace()
        let a = work.appendingPathComponent("a")
        let b = work.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)

        let source = repoRoot().appendingPathComponent("Tests/ShrinkerProTests/Fixtures/sample.png")
        try FileManager.default.copyItem(at: source, to: a.appendingPathComponent("logo.png"))
        try FileManager.default.copyItem(at: source, to: b.appendingPathComponent("logo.png"))

        let out = work.appendingPathComponent("out")
        let result = try run(
            ["--if-exists", "keep-both", "--out", out.path,
             a.appendingPathComponent("logo.png").path,
             b.appendingPathComponent("logo.png").path],
            helpers: helpers
        )

        XCTAssertEqual(result.code, 0, result.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("logo.min.png").path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: out.appendingPathComponent("logo.min 2.png").path),
            "both results must survive"
        )
    }

    /// The other three modes keep refusing, unchanged. Pinned to the exact
    /// exit code and to the message naming the colliding file — the same two
    /// things `testTwoInputsThatWouldOverwriteEachOtherAreRefused` pins for
    /// the default mode — so a refusal that degraded into a crash, or into
    /// some other non-zero code, would still be caught.
    func testSkipAndFailStillRefuseTwoInputsThatWouldCollide() throws {
        let helpers = try stagedHelpers()
        for mode in ["skip", "fail"] {
            let work = try workspace()
            let a = work.appendingPathComponent("a")
            let b = work.appendingPathComponent("b")
            try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
            let source = repoRoot().appendingPathComponent("Tests/ShrinkerProTests/Fixtures/sample.png")
            try FileManager.default.copyItem(at: source, to: a.appendingPathComponent("logo.png"))
            try FileManager.default.copyItem(at: source, to: b.appendingPathComponent("logo.png"))

            let result = try run(
                ["--if-exists", mode, "--out", work.appendingPathComponent("out").path,
                 a.appendingPathComponent("logo.png").path,
                 b.appendingPathComponent("logo.png").path],
                helpers: helpers
            )

            XCTAssertEqual(result.code, 65, "--if-exists \(mode) must still refuse a two-input collision as EX_DATAERR")
            XCTAssertTrue(
                result.stderr.contains("logo.png"),
                "--if-exists \(mode): the message must name the file that collides, got: \(result.stderr)"
            )
        }
    }

    /// Not just that both survive, but that the mapping is the right way
    /// round: the first input in the list keeps the plain name, and every
    /// later input sharing it is the one that gets numbered — the Finder
    /// convention this feature imitates, and the reverse of what an earlier,
    /// less careful claim-tracking scheme produced (it inverted the mapping
    /// while still leaving both files on disk, which a same-filenames-only
    /// assertion could not have caught).
    func testKeepBothKeepsTheFirstInputsPlainNameAndNumbersLaterOnes() throws {
        let helpers = try stagedHelpers()
        let work = try workspace()
        let a = work.appendingPathComponent("a")
        let b = work.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)

        let source = repoRoot().appendingPathComponent("Tests/ShrinkerProTests/Fixtures/sample.png")
        let firstInput = a.appendingPathComponent("logo.png")
        let secondInput = b.appendingPathComponent("logo.png")
        try FileManager.default.copyItem(at: source, to: firstInput)
        try FileManager.default.copyItem(at: source, to: secondInput)

        let out = work.appendingPathComponent("out")
        let result = try run(
            ["--if-exists", "keep-both", "--out", out.path, "--json", firstInput.path, secondInput.path],
            helpers: helpers
        )

        XCTAssertEqual(result.code, 0, result.stderr)
        let lines = result.stdout
            .split(separator: "\n")
            .map { try? XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
            .compactMap { $0 }
        XCTAssertEqual(lines.count, 2, "expected one JSON line per input, got: \(result.stdout)")

        let byInput = Dictionary(uniqueKeysWithValues: lines.map { ($0["input"] as? String ?? "", $0["output"] as? String ?? "") })

        XCTAssertEqual(
            byInput[firstInput.path], out.appendingPathComponent("logo.min.png").path,
            "the first input must keep the plain name"
        )
        XCTAssertEqual(
            byInput[secondInput.path], out.appendingPathComponent("logo.min 2.png").path,
            "the second input, which arrived after the first already claimed the plain name, must be the one numbered"
        )
    }
}
