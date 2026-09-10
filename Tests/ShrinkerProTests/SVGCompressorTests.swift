import XCTest
@testable import ShrinkerPro

final class SVGCompressorTests: XCTestCase {

    /// A missing bundled resource in a built product is a broken build, not
    /// "nothing to check" — so this fails hard rather than XCTSkip, which
    /// would silently report SVG compression as untested. (Contrast with
    /// ArchitectureGuardTests.builtAppURL(), which legitimately skips when
    /// the app was never built at all.)
    private struct MissingTestResource: Error {}

    private func makeCompressor() throws -> SVGCompressor {
        let bundle = Bundle(for: SVGCompressorTests.self)
        guard let script = Bundle.main.url(forResource: "svgo.jsc", withExtension: "js")
            ?? bundle.url(forResource: "svgo.jsc", withExtension: "js") else {
            XCTFail("svgo.jsc.js not bundled — run scripts/prepare-svgo.sh, then xcodegen generate")
            throw MissingTestResource()
        }
        return try SVGCompressor(scriptURL: script)
    }

    func testShrinksSVGAndStripsComment() throws {
        let compressor = try makeCompressor()
        let input = try fixture("sample", "svg")
        let output = tempURL("out.svg")
        defer { try? FileManager.default.removeItem(at: output) }

        try compressor.compress(input: input, output: output)

        let before = try Data(contentsOf: input)
        let after = try Data(contentsOf: output)
        let text = String(decoding: after, as: UTF8.self)

        XCTAssertLessThan(after.count, before.count, "svgo did not reduce the file")
        XCTAssertFalse(text.contains("removable comment"), "comment survived optimization")
        XCTAssertTrue(text.hasPrefix("<svg"), "output is not an SVG document: \(text.prefix(40))")
    }

    func testReportsInvalidSVGAsError() throws {
        let compressor = try makeCompressor()
        let input = tempURL("bad.svg")
        try "<svg><unclosed>".write(to: input, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: input) }

        XCTAssertThrowsError(try compressor.compress(input: input, output: tempURL("bad.out.svg"))) { error in
            guard case ShrinkError.javascriptFailed = error else {
                return XCTFail("expected .javascriptFailed, got \(error)")
            }
        }
    }

    // MARK: - Helpers

    func fixture(_ name: String, _ ext: String) throws -> URL {
        let bundle = Bundle(for: SVGCompressorTests.self)
        guard let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: ext) else {
            XCTFail("fixture \(name).\(ext) not found in test bundle — check project.yml's Fixtures resource entry and re-run xcodegen generate")
            throw MissingTestResource()
        }
        return url
    }

    func tempURL(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString)-\(name)")
    }
}
