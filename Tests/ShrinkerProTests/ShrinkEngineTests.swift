import XCTest
@testable import ShrinkerPro

final class ShrinkEngineTests: XCTestCase {

    /// A missing bundled resource, vendored binary, or fixture in a
    /// checked-out build is a broken build, not "nothing to check" — so
    /// these fail hard rather than XCTSkip, which would silently report
    /// ShrinkEngine as untested. See SVGCompressorTests.swift for the same
    /// house pattern.
    private struct MissingTestResource: Error {}

    private func vendorCompressorsRoot() throws -> URL {
        let repoRoot = ProcessInfo.processInfo.environment["SRCROOT"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let vendor = repoRoot.appendingPathComponent("vendor/compressors")
        guard FileManager.default.isExecutableFile(atPath: vendor.appendingPathComponent("cjpeg").path) else {
            XCTFail("compressors not built — run scripts/build-compressors.sh")
            throw MissingTestResource()
        }
        return vendor
    }

    private func svgoScriptURL() throws -> URL {
        let bundle = Bundle(for: ShrinkEngineTests.self)
        guard let svgo = Bundle.main.url(forResource: "svgo.jsc", withExtension: "js")
            ?? bundle.url(forResource: "svgo.jsc", withExtension: "js") else {
            XCTFail("svgo.jsc.js not bundled — run scripts/prepare-svgo.sh, then xcodegen generate")
            throw MissingTestResource()
        }
        return svgo
    }

    private func makeEngine() throws -> ShrinkEngine {
        let vendor = try vendorCompressorsRoot()
        return try ShrinkEngine(
            helperProvider: { vendor.appendingPathComponent($0) },
            svgoScriptURL: try svgoScriptURL()
        )
    }

    private func stagedFixture(_ name: String, _ ext: String) throws -> URL {
        let bundle = Bundle(for: ShrinkEngineTests.self)
        guard let source = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: ext) else {
            XCTFail("fixture \(name).\(ext) not found in test bundle — check project.yml's Fixtures resource entry and re-run xcodegen generate")
            throw MissingTestResource()
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let staged = dir.appendingPathComponent("\(name).\(ext)")
        try FileManager.default.copyItem(at: source, to: staged)
        return staged
    }

    private let defaults = OutputSettings(
        saveInSameFolder: true, savePath: nil, useSubfolder: false, keepOriginal: true
    )

    func testShrinksEachSupportedFormat() throws {
        let engine = try makeEngine()
        for (name, ext) in [("sample", "jpg"), ("sample", "png"), ("sample", "gif"), ("sample", "svg")] {
            let input = try stagedFixture(name, ext)
            defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }

            let result = try engine.shrink(input, settings: defaults)

            XCTAssertEqual(result.output.lastPathComponent, "sample.min.\(ext)")
            XCTAssertGreaterThan(result.originalBytes, 0, "\(ext): no original size")
            XCTAssertLessThan(result.shrunkBytes, result.originalBytes, "\(ext): did not shrink")
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.output.path))
        }
    }

    // MARK: - Format conversion (end-to-end, real binaries + ImageIO)

    /// Same base output settings as `defaults`, with conversion rules
    /// overridden for this specific test. `ConversionRules()`'s own
    /// defaults are all `.keep`, so only the format under test needs a
    /// non-default value named explicitly.
    private func settings(rules: ConversionRules) -> OutputSettings {
        OutputSettings(
            saveInSameFolder: true, savePath: nil, useSubfolder: false, keepOriginal: true,
            conversionRules: rules
        )
    }

    /// The spec's one opinionated default, exercised end-to-end: a HEIC
    /// photo becomes a real, smaller JPEG via the TGA-intermediate path
    /// (cjpeg cannot read HEIC directly), and the extension on disk
    /// actually changes — this is also what proves `OutputPathResolver`'s
    /// `targetExtension` plumbing is wired correctly, not just unit-tested
    /// in isolation.
    func testHEICConvertsToJPEGByDefault() throws {
        let engine = try makeEngine()
        let input = try stagedFixture("sample", "heic")
        defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }

        let result = try engine.shrink(input, settings: settings(rules: ConversionRules(heic: .jpeg)))

        XCTAssertEqual(result.output.lastPathComponent, "sample.min.jpg")
        XCTAssertEqual(result.output.deletingLastPathComponent(), input.deletingLastPathComponent())
        XCTAssertGreaterThan(result.shrunkBytes, 0)
        let bytes = try Data(contentsOf: result.output)
        XCTAssertEqual(Array(bytes.prefix(3)), [0xFF, 0xD8, 0xFF], "output is not a JPEG")

        // The spec is explicit: converting must never touch the original,
        // and here it can't even collide — the extensions differ.
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.path), "original HEIC was deleted")
    }

    /// PNG → WebP: cwebp reads PNG directly, so this is `ConversionRoute
    /// .direct`, no ImageIO intermediate at all.
    func testPNGConvertsToWebP() throws {
        let engine = try makeEngine()
        let input = try stagedFixture("sample", "png")
        defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }

        let result = try engine.shrink(input, settings: settings(rules: ConversionRules(png: .webp)))

        XCTAssertEqual(result.output.lastPathComponent, "sample.min.webp")
        XCTAssertLessThan(result.shrunkBytes, result.originalBytes)
        let bytes = try Data(contentsOf: result.output)
        XCTAssertEqual(Array(bytes.prefix(4)), Array("RIFF".utf8), "output is not RIFF/WebP")
    }

    /// PNG → AVIF: ImageIO decodes PNG and encodes AVIF directly, no
    /// vendored binary at all — `ConversionRoute.direct`.
    func testPNGConvertsToAVIF() throws {
        let engine = try makeEngine()
        let input = try stagedFixture("sample", "png")
        defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }

        let result = try engine.shrink(input, settings: settings(rules: ConversionRules(png: .avif)))

        XCTAssertEqual(result.output.lastPathComponent, "sample.min.avif")
        XCTAssertLessThan(result.shrunkBytes, result.originalBytes)
        // ftyp box for an AVIF ISO-BMFF container names its major brand at
        // byte offset 8 ("....ftypavif").
        let bytes = try Data(contentsOf: result.output)
        XCTAssertGreaterThan(bytes.count, 12)
        XCTAssertEqual(String(decoding: bytes[4..<8], as: UTF8.self), "ftyp")
        XCTAssertEqual(String(decoding: bytes[8..<12], as: UTF8.self), "avif")
    }

    /// HEIC → WebP: cwebp cannot read HEIC at all, so this must go
    /// through the PNG intermediate — `ConversionRoute.viaIntermediate`.
    /// The most indirect path in the whole router; if the intermediate
    /// leaks or isn't cleaned up, or the wrong UTI is used, this is where
    /// it would show up.
    func testHEICConvertsToWebPViaIntermediate() throws {
        let engine = try makeEngine()
        let input = try stagedFixture("sample", "heic")
        defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }

        let result = try engine.shrink(input, settings: settings(rules: ConversionRules(heic: .webp)))

        XCTAssertEqual(result.output.lastPathComponent, "sample.min.webp")
        XCTAssertGreaterThan(result.shrunkBytes, 0)
        let bytes = try Data(contentsOf: result.output)
        XCTAssertEqual(Array(bytes.prefix(4)), Array("RIFF".utf8), "output is not RIFF/WebP")

        // Only the real output and the untouched original should remain —
        // no leaked .png intermediate.
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: input.deletingLastPathComponent().path
        )
        XCTAssertEqual(Set(leftovers), ["sample.heic", "sample.min.webp"])
    }

    /// AVIF → JPEG: cjpeg cannot read AVIF either, so this also goes
    /// through an intermediate, this time TGA.
    func testAVIFConvertsToJPEGViaIntermediate() throws {
        let engine = try makeEngine()
        let input = try stagedFixture("sample", "avif")
        defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }

        let result = try engine.shrink(input, settings: settings(rules: ConversionRules(avif: .jpeg)))

        XCTAssertEqual(result.output.lastPathComponent, "sample.min.jpg")
        XCTAssertGreaterThan(result.shrunkBytes, 0)
        let bytes = try Data(contentsOf: result.output)
        XCTAssertEqual(Array(bytes.prefix(3)), [0xFF, 0xD8, 0xFF], "output is not a JPEG")
    }

    /// WebP and AVIF "keep" both mean "re-encode in the same container" —
    /// there's no dedicated re-optimiser for either, so this is ImageIO
    /// decode+re-encode, still shrinking a real file end-to-end.
    func testWebPAndAVIFKeepStillShrink() throws {
        let engine = try makeEngine()
        for (name, ext) in [("sample", "webp"), ("sample", "avif")] {
            let input = try stagedFixture(name, ext)
            defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }

            let result = try engine.shrink(input, settings: defaults) // ConversionRules() == all .keep
            XCTAssertEqual(result.output.lastPathComponent, "sample.min.\(ext)", ext)
            XCTAssertGreaterThan(result.shrunkBytes, 0, ext)
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.output.path), ext)
        }
    }

    /// SVG and GIF have no rule row at all — `ConversionRules` has no
    /// field for either — so they must optimise in their own format no
    /// matter how aggressively every *other* format's rule is set to
    /// convert. This end-to-end proof uses rules that convert every
    /// convertible format to WebP, then confirms SVG/GIF are entirely
    /// unaffected: still their own format, still shrunk.
    func testSVGAndGIFNeverConvertRegardlessOfOtherRules() throws {
        let engine = try makeEngine()
        let aggressive = settings(
            rules: ConversionRules(png: .webp, jpeg: .webp, heic: .webp, webp: .keep, avif: .webp)
        )

        for (name, ext, magic) in [
            ("sample", "svg", Array("<svg".utf8)),
            ("sample", "gif", Array("GIF8".utf8)),
        ] {
            let input = try stagedFixture(name, ext)
            defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }

            let result = try engine.shrink(input, settings: aggressive)

            XCTAssertEqual(result.output.lastPathComponent, "sample.min.\(ext)", "\(ext) must not convert")
            XCTAssertLessThan(result.shrunkBytes, result.originalBytes, ext)
            let bytes = try Data(contentsOf: result.output)
            XCTAssertEqual(Array(bytes.prefix(magic.count)), magic, "\(ext): wrong magic bytes after conversion rules applied")
        }
    }

    func testUnsupportedExtensionThrows() throws {
        let engine = try makeEngine()
        let bogus = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("a-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }

        XCTAssertThrowsError(try engine.shrink(bogus, settings: defaults)) { error in
            guard case ShrinkError.unsupportedFormat(let ext) = error else {
                return XCTFail("expected .unsupportedFormat, got \(error)")
            }
            XCTAssertEqual(ext, "txt")
        }
    }

    func testExtensionMatchingIsCaseInsensitive() throws {
        let engine = try makeEngine()
        let input = try stagedFixture("sample", "png")
        let upper = input.deletingLastPathComponent().appendingPathComponent("SAMPLE.PNG")
        try FileManager.default.moveItem(at: input, to: upper)
        defer { try? FileManager.default.removeItem(at: upper.deletingLastPathComponent()) }

        let result = try engine.shrink(upper, settings: defaults)
        XCTAssertLessThan(result.shrunkBytes, result.originalBytes)
    }

    /// A fresh clone that never ran scripts/prepare-svgo.sh has no
    /// svgo.jsc.js. ShrinkEngine.init must turn that into
    /// `.helperMissing("svgo.jsc.js")`, not a raw Foundation
    /// file-not-found error escaping from SVGCompressor's
    /// `String(contentsOf:)`. This test can't blank out the real
    /// Bundle.main (the hosted test app legitimately bundles the script),
    /// so it exercises the same guard the production nil-defaulted path
    /// runs through by pointing `svgoScriptURL` at a path that does not
    /// exist on disk.
    func testMissingSvgoScriptThrowsHelperMissing() {
        let missingScript = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("no-such-dir-\(UUID().uuidString)")
            .appendingPathComponent("svgo.jsc.js")

        XCTAssertThrowsError(
            try ShrinkEngine(
                helperProvider: { name in URL(fileURLWithPath: "/nonexistent/\(name)") },
                svgoScriptURL: missingScript
            )
        ) { error in
            guard case ShrinkError.helperMissing(let name) = error else {
                return XCTFail("expected .helperMissing, got \(error)")
            }
            XCTAssertEqual(name, "svgo.jsc.js")
        }
    }

    /// Fix round 1: the default `helperProvider` used to swallow
    /// `HelperLocator`'s thrown error with `try?` and silently fall back to
    /// an unvalidated `Contents/Helpers/<name>` path — so on a damaged
    /// install missing a bundled binary, `ProcessRunner` would hit that
    /// nonexistent path directly and a raw `NSCocoaErrorDomain` error would
    /// reach the caller instead of `.helperMissing`. This test points a
    /// `helperProvider` at the real `HelperLocator.url(named:in:)` (the same
    /// call the production default now makes, just with a bundle rooted at
    /// a directory that genuinely has no `Contents/Helpers/cjpeg`) and
    /// checks that `shrink()` still surfaces the typed `ShrinkError` rather
    /// than whatever `Process` throws when told to launch a path that isn't
    /// there.
    func testMissingHelperSurfacesHelperMissingNotRawError() throws {
        let emptyRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("no-helpers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyRoot) }
        guard let fakeBundle = Bundle(url: emptyRoot) else {
            XCTFail("could not construct a Bundle for \(emptyRoot.path)")
            throw MissingTestResource()
        }

        let engine = try ShrinkEngine(
            helperProvider: { name in try HelperLocator.url(named: name, in: fakeBundle) },
            svgoScriptURL: try svgoScriptURL()
        )

        let input = try stagedFixture("sample", "jpg")
        defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }

        XCTAssertThrowsError(try engine.shrink(input, settings: defaults)) { error in
            guard case ShrinkError.helperMissing(let name) = error else {
                return XCTFail("expected .helperMissing, got \(error) (\(type(of: error)))")
            }
            XCTAssertEqual(name, "cjpeg")
        }
    }

    /// Opposite direction of the test above: a helper that genuinely exists
    /// and is executable must still resolve and let compression succeed.
    /// Without this, an over-strict fix for the missing-helper case (e.g.
    /// checking the wrong path, or a bundle-relative computation that's
    /// subtly wrong) could reject a perfectly good helper and nothing above
    /// would catch it — every other test here injects a `helperProvider`
    /// that never goes through `HelperLocator` at all. This one builds a
    /// throwaway `Contents/Helpers/` directory populated with the real
    /// vendored binaries and resolves through the actual
    /// `HelperLocator.url(named:in:)` call the production default uses.
    func testPresentExecutableHelperResolvesAndCompressionSucceeds() throws {
        let vendor = try vendorCompressorsRoot()

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("has-helpers-\(UUID().uuidString)")
        let helpersDir = root.appendingPathComponent("Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpersDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(
            at: vendor.appendingPathComponent("cjpeg"), to: helpersDir.appendingPathComponent("cjpeg")
        )
        guard let fakeBundle = Bundle(url: root) else {
            XCTFail("could not construct a Bundle for \(root.path)")
            throw MissingTestResource()
        }

        let engine = try ShrinkEngine(
            helperProvider: { name in try HelperLocator.url(named: name, in: fakeBundle) },
            svgoScriptURL: try svgoScriptURL()
        )

        let input = try stagedFixture("sample", "jpg")
        defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }

        let result = try engine.shrink(input, settings: defaults)
        XCTAssertLessThan(result.shrunkBytes, result.originalBytes, "compression did not shrink")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.output.path))
    }

    // MARK: - In-place (destructive) mode

    /// With both `.min` suffix and `minified/` subfolder off, the resolved
    /// output path IS the input path: compression happens over the user's
    /// original, with no second copy anywhere. Every test below uses this
    /// configuration because it is the only one where a compressor bug
    /// costs the user data rather than a regenerable derivative.
    private let inPlace = OutputSettings(
        saveInSameFolder: true, savePath: nil, useSubfolder: false, keepOriginal: false
    )

    /// Copies a fixture to a private directory and corrupts it so its
    /// compressor is guaranteed to fail on it.
    ///
    /// Truncation to half length (a partial download, damaged media) is the
    /// realistic corruption a user actually drops on the app, and it is
    /// what PNG and GIF use: the header and early frames parse fine, so the
    /// tool commits to writing output and only discovers the problem
    /// partway through the data. cjpeg is deliberately the exception —
    /// libjpeg *recovers* from a truncated scan and exits 0 with a valid
    /// (short) JPEG, verified here — so the JPEG case needs content that is
    /// not a JPEG at all to reach a failure path.
    private func stagedCorruptFixture(_ name: String, _ ext: String) throws -> URL {
        let staged = try stagedFixture(name, ext)
        if ext == "jpg" || ext == "jpeg" {
            try Data("not a valid jpeg at all".utf8).write(to: staged)
        } else {
            let full = try Data(contentsOf: staged)
            XCTAssertGreaterThan(full.count, 2, "fixture \(name).\(ext) too small to truncate")
            try full.prefix(full.count / 2).write(to: staged)
        }
        return staged
    }

    /// Asserts that shrinking `input` in place fails, and that the original
    /// bytes are still on disk completely unchanged afterwards — compared
    /// byte-for-byte, not by size, since a same-size-but-different file is
    /// just as destroyed.
    private func assertInPlaceFailureLeavesOriginalIntact(
        _ engine: ShrinkEngine,
        _ input: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let before = try Data(contentsOf: input)

        XCTAssertThrowsError(try engine.shrink(input, settings: inPlace), file: file, line: line) { error in
            guard case ShrinkError.compressorFailed = error else {
                return XCTFail("expected .compressorFailed, got \(error)", file: file, line: line)
            }
        }

        let after = try Data(contentsOf: input)
        XCTAssertEqual(
            after, before,
            "a failed in-place shrink modified the user's original file "
                + "(\(before.count) bytes before, \(after.count) after)",
            file: file, line: line
        )

        // The engine's scratch file must not survive a failure either.
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: input.deletingLastPathComponent().path
        ).filter { $0 != input.lastPathComponent }
        XCTAssertTrue(leftovers.isEmpty, "files left behind: \(leftovers)", file: file, line: line)
    }

    /// gifsicle destroys its `-o` target on a truncated GIF. Its own
    /// `output_frames()` call is gated on `error_count == 0`
    /// (vendor/src/gifsicle/src/gifsicle.c:2225), but read errors are
    /// deliberately rolled back before that gate is reached — see
    /// `if (!no_ignore_errors) error_count = old_error_count;` at
    /// gifsicle.c:746. So the gate sees zero, output_frames() truncates the
    /// target, and only afterwards is the buffered error re-raised as exit
    /// status 1. Reproduced against the shipped binary with GIFCompressor's
    /// exact argv and output == input: a 61156-byte truncated GIF came back
    /// as 835 bytes with exit code 1.
    func testInPlaceGIFOriginalSurvivesCompressorFailure() throws {
        let engine = try makeEngine()
        let input = try stagedCorruptFixture("sample", "gif")
        defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }
        try assertInPlaceFailureLeavesOriginalIntact(engine, input)
    }

    /// cjpeg opens its `-outfile` with "wb" before libjpeg has decoded
    /// anything, so on undecodable input the target is truncated to 0 bytes
    /// and only then is the failure reported. Verified against the vendored
    /// binary: `cjpeg -outfile same.jpg same.jpg` on non-JPEG content
    /// leaves same.jpg at 0 bytes with exit code 1.
    func testInPlaceJPEGOriginalSurvivesCompressorFailure() throws {
        let engine = try makeEngine()
        let input = try stagedCorruptFixture("sample", "jpg")
        defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }
        try assertInPlaceFailureLeavesOriginalIntact(engine, input)
    }

    /// pngquant happens to write to a private tempname and rename on
    /// success, so *this particular version* leaves a truncated PNG alone
    /// on its own (checked: exit 25, file unchanged). That is an
    /// observation about today's binary, not a guarantee — a pngquant
    /// upgrade could change it silently. This test pins the behavior the
    /// user actually depends on (the original survives), which the engine
    /// now enforces regardless of what pngquant does.
    func testInPlacePNGOriginalSurvivesCompressorFailure() throws {
        let engine = try makeEngine()
        let input = try stagedCorruptFixture("sample", "png")
        defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }
        try assertInPlaceFailureLeavesOriginalIntact(engine, input)
    }

    /// The three tests above depend on how today's vendored binaries
    /// happen to misbehave; this one depends on nothing. It substitutes a
    /// helper that unconditionally truncates whatever path it was told to
    /// write to and then fails — the worst thing a compressor could
    /// possibly do — and proves the user's original still survives. This is
    /// the test that actually pins the engine-level invariant: no
    /// compressor is ever handed the user's file as its write target, so no
    /// compressor has to be trusted, including a fifth one added later.
    func testInPlaceOriginalSurvivesDestructiveHelper() throws {
        let helperDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("destructive-helper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: helperDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: helperDir) }

        // PNGCompressor's argv is ["-fo", <output>, <input>], so "$2" is
        // whatever the engine nominated as the write target.
        let helper = helperDir.appendingPathComponent("pngquant")
        try #"""
        #!/bin/sh
        : > "$2"
        echo "destroyed $2" >&2
        exit 1
        """#.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let engine = try ShrinkEngine(
            helperProvider: { helperDir.appendingPathComponent($0) },
            svgoScriptURL: try svgoScriptURL()
        )

        let input = try stagedFixture("sample", "png")
        defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }
        try assertInPlaceFailureLeavesOriginalIntact(engine, input)
    }

    /// The other half of the invariant: staging through a scratch file must
    /// not break the success path. Every format must still overwrite the
    /// original in place with a smaller, valid file and leave no scratch
    /// file behind.
    func testInPlaceShrinkOverwritesOriginalAndLeavesNoScratch() throws {
        let engine = try makeEngine()
        let magics: [String: [UInt8]] = [
            "jpg": [0xFF, 0xD8, 0xFF],
            "png": [0x89, 0x50, 0x4E, 0x47],
            "gif": Array("GIF8".utf8),
            "svg": Array("<svg".utf8),
        ]
        for (ext, magic) in magics {
            let input = try stagedFixture("sample", ext)
            defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }
            let originalBytes = try Data(contentsOf: input).count

            let result = try engine.shrink(input, settings: inPlace)

            XCTAssertEqual(result.output, input, "\(ext): output path is not the input path")
            let after = try Data(contentsOf: input)
            XCTAssertGreaterThan(after.count, 0, "\(ext): in-place shrink produced an empty file")
            XCTAssertLessThan(after.count, originalBytes, "\(ext): in-place shrink did not shrink")
            XCTAssertEqual(Array(after.prefix(magic.count)), magic, "\(ext): output has wrong magic bytes")

            let leftovers = try FileManager.default.contentsOfDirectory(
                atPath: input.deletingLastPathComponent().path
            ).filter { $0 != input.lastPathComponent }
            XCTAssertTrue(leftovers.isEmpty, "\(ext): files left behind: \(leftovers)")
        }
    }

    // Upstream: Math.round((100 / sizeBefore) * (sizeBefore - sizeAfter))
    func testSavedPercentMatchesUpstreamFormula() {
        XCTAssertEqual(ShrinkResult(input: URL(fileURLWithPath: "/a"), output: URL(fileURLWithPath: "/b"),
                                    originalBytes: 1000, shrunkBytes: 250).savedPercent, 75)
        XCTAssertEqual(ShrinkResult(input: URL(fileURLWithPath: "/a"), output: URL(fileURLWithPath: "/b"),
                                    originalBytes: 1000, shrunkBytes: 1000).savedPercent, 0)
        XCTAssertEqual(ShrinkResult(input: URL(fileURLWithPath: "/a"), output: URL(fileURLWithPath: "/b"),
                                    originalBytes: 3, shrunkBytes: 2).savedPercent, 33)
        // Guard against divide-by-zero on an empty input.
        XCTAssertEqual(ShrinkResult(input: URL(fileURLWithPath: "/a"), output: URL(fileURLWithPath: "/b"),
                                    originalBytes: 0, shrunkBytes: 0).savedPercent, 0)
    }
}
