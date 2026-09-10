import XCTest
@testable import ShrinkerPro

final class BinaryCompressorTests: XCTestCase {

    /// A missing helper binary or fixture in a built/checked-out product is a
    /// broken build, not "nothing to check" — so these fail hard rather than
    /// XCTSkip, which would silently report these compressors as untested.
    /// See SVGCompressorTests.swift for the same house pattern.
    private struct MissingTestResource: Error {}

    /// Tests run from a test bundle, not the app bundle, so point directly at
    /// the build output of scripts/build-compressors.sh.
    private func helper(_ name: String) throws -> URL {
        let repoRoot = ProcessInfo.processInfo.environment["SRCROOT"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent("vendor/compressors/\(name)")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            XCTFail("\(name) not built — run scripts/build-compressors.sh")
            throw MissingTestResource()
        }
        return url
    }

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        let bundle = Bundle(for: BinaryCompressorTests.self)
        guard let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: ext) else {
            XCTFail("fixture \(name).\(ext) not found in test bundle — check project.yml's Fixtures resource entry and re-run xcodegen generate")
            throw MissingTestResource()
        }
        return url
    }

    private func tempURL(_ ext: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).\(ext)")
    }

    private func assertShrunk(_ input: URL, _ output: URL, magic: [UInt8], file: StaticString = #filePath, line: UInt = #line) throws {
        let before = try Data(contentsOf: input)
        let after = try Data(contentsOf: output)
        XCTAssertLessThan(after.count, before.count, "output not smaller", file: file, line: line)
        XCTAssertGreaterThan(after.count, 0, "output is empty", file: file, line: line)
        XCTAssertEqual(Array(after.prefix(magic.count)), magic, "wrong magic bytes", file: file, line: line)
    }

    func testJPEGCompression() throws {
        let input = try fixture("sample", "jpg")
        let output = tempURL("jpg")
        defer { try? FileManager.default.removeItem(at: output) }

        let compressor = JPEGCompressor(executable: try helper("cjpeg"))
        try compressor.compress(input: input, output: output)
        try assertShrunk(input, output, magic: [0xFF, 0xD8, 0xFF])
    }

    /// The half of the `Compressor` contract that `ShrinkEngine`'s scratch
    /// staging cannot enforce: a compressor must never write to `input`.
    /// The engine protects the user's file by never nominating it as
    /// `output`, but if a tool decided to rewrite its *source* argument in
    /// place, nothing upstream of it could help. This is also the reason
    /// the two former in-place JPEG tests moved to ShrinkEngineTests:
    /// JPEGCompressor no longer stages privately, so "survives a failed
    /// in-place run" is now a property of the engine, tested there against
    /// all four formats plus a deliberately destructive helper.
    ///
    /// PNG and GIF use truncated fixtures, so each tool fails partway
    /// through rather than rejecting the input outright — the case where a
    /// tool is most likely to have already opened files for writing. cjpeg
    /// gets non-JPEG content instead: libjpeg *recovers* from a truncated
    /// scan and exits 0 with a valid short JPEG (verified — a fixture
    /// truncated to 50% compresses fine), so truncation would not reach a
    /// failure path for it at all.
    func testCompressorsNeverWriteToTheirInput() throws {
        let cases: [(String, String, Compressor)] = [
            ("cjpeg", "jpg", JPEGCompressor(executable: try helper("cjpeg"))),
            ("pngquant", "png", PNGCompressor(executable: try helper("pngquant"))),
            ("gifsicle", "gif", GIFCompressor(executable: try helper("gifsicle"))),
        ]

        for (tool, ext, compressor) in cases {
            let input = tempURL(ext)
            let corrupt: Data
            if ext == "jpg" {
                corrupt = Data("not a valid jpeg at all".utf8)
            } else {
                let full = try Data(contentsOf: try fixture("sample", ext))
                corrupt = Data(full.prefix(full.count / 2))
            }
            try corrupt.write(to: input)
            let output = tempURL(ext)
            defer {
                try? FileManager.default.removeItem(at: input)
                try? FileManager.default.removeItem(at: output)
            }

            XCTAssertThrowsError(try compressor.compress(input: input, output: output)) { error in
                guard case ShrinkError.compressorFailed(let failed, _, _) = error else {
                    return XCTFail("\(tool): expected .compressorFailed, got \(error)")
                }
                XCTAssertEqual(failed, tool)
            }

            XCTAssertEqual(
                try Data(contentsOf: input), corrupt,
                "\(tool) modified its own input file"
            )
        }
    }

    func testPNGCompression() throws {
        let input = try fixture("sample", "png")
        let output = tempURL("png")
        defer { try? FileManager.default.removeItem(at: output) }

        try PNGCompressor(executable: try helper("pngquant")).compress(input: input, output: output)
        try assertShrunk(input, output, magic: [0x89, 0x50, 0x4E, 0x47])
    }

    func testGIFCompression() throws {
        let input = try fixture("sample", "gif")
        let output = tempURL("gif")
        defer { try? FileManager.default.removeItem(at: output) }

        try GIFCompressor(executable: try helper("gifsicle")).compress(input: input, output: output)
        try assertShrunk(input, output, magic: Array("GIF8".utf8))
    }

    func testFailureSurfacesCompressorError() throws {
        let bogus = tempURL("png")
        try Data("not a png".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }

        XCTAssertThrowsError(
            try PNGCompressor(executable: try helper("pngquant"))
                .compress(input: bogus, output: tempURL("png"))
        ) { error in
            guard case ShrinkError.compressorFailed(let tool, _, _) = error else {
                return XCTFail("expected .compressorFailed, got \(error)")
            }
            XCTAssertEqual(tool, "pngquant")
        }
    }
}
