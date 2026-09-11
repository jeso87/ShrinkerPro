import XCTest
import ImageIO
@testable import ShrinkerPro

/// The regression test for the bug users actually reported: photographs
/// coming out of the app rotated wrongly.
///
/// These run the real engine over a real fixture with the real vendored
/// binaries, and assert on the file that lands on disk — not on a routing
/// decision. A rotation bug is only truly fixed if the *output* is upright,
/// and the two are separable: the route can be right while the transform is
/// turned the wrong way, and vice versa.
final class OrientationEndToEndTests: XCTestCase {

    private struct MissingTestResource: Error {}

    private func makeEngine() throws -> ShrinkEngine {
        let repoRoot = ProcessInfo.processInfo.environment["SRCROOT"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let vendor = repoRoot.appendingPathComponent("vendor/compressors")
        guard FileManager.default.isExecutableFile(atPath: vendor.appendingPathComponent("cjpeg").path) else {
            XCTFail("compressors not built — run scripts/build-compressors.sh")
            throw MissingTestResource()
        }
        let bundle = Bundle(for: OrientationEndToEndTests.self)
        guard let svgo = Bundle.main.url(forResource: "svgo.jsc", withExtension: "js")
            ?? bundle.url(forResource: "svgo.jsc", withExtension: "js") else {
            XCTFail("svgo.jsc.js not bundled — run scripts/prepare-svgo.sh, then xcodegen generate")
            throw MissingTestResource()
        }
        return try ShrinkEngine(helperProvider: { vendor.appendingPathComponent($0) }, svgoScriptURL: svgo)
    }

    private func staged(_ name: String, _ ext: String) throws -> URL {
        let bundle = Bundle(for: OrientationEndToEndTests.self)
        guard let source = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: ext) else {
            XCTFail("fixture \(name).\(ext) not found — regenerate with scripts/make-orientation-fixtures.swift")
            throw MissingTestResource()
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("orientation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let staged = dir.appendingPathComponent("\(name).\(ext)")
        try FileManager.default.copyItem(at: source, to: staged)
        return staged
    }

    private func settings(
        sessionFormat: SessionFormat? = nil,
        policy: MetadataPolicy = .all,
        rules: ConversionRules = ConversionRules()
    ) -> OutputSettings {
        OutputSettings(
            saveInSameFolder: true, savePath: nil, useSubfolder: false, keepOriginal: true,
            conversionRules: rules, metadataPolicy: policy, sessionFormat: sessionFormat
        )
    }

    /// The fixture is stored 200x100 and tagged "rotate 90° clockwise", so
    /// it *displays* 100x200. An output that is still 200 wide means the
    /// rotation was dropped; an output carrying an orientation tag means it
    /// was merely forwarded, which viewers honour inconsistently.
    private func assertUpright(
        _ url: URL, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), file: file, line: line)
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            file: file, line: line
        )
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 100,
                       "\(url.lastPathComponent) is not upright — the rotation was not baked in",
                       file: file, line: line)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 200,
                       "\(url.lastPathComponent) is not upright — the rotation was not baked in",
                       file: file, line: line)

        let orientation = (properties[kCGImagePropertyOrientation] as? UInt32) ?? 1
        XCTAssertEqual(orientation, 1,
                       "\(url.lastPathComponent) still carries an orientation tag, which would turn it a second time",
                       file: file, line: line)
    }

    /// HEIC -> JPEG is the default rule and the case actually reported: an
    /// iPhone photo dropped on the app with no settings changed.
    func testHEICToJPEGComesOutUpright() throws {
        let input = try staged("rotated", "heic")
        let result = try makeEngine().shrink(input, settings: settings())
        XCTAssertEqual(result.output.pathExtension, "jpg")
        try assertUpright(result.output)
    }

    func testEveryConversionTargetComesOutUpright() throws {
        let engine = try makeEngine()
        for format in SessionFormat.allCases {
            let input = try staged("rotated", "heic")
            let result = try engine.shrink(input, settings: settings(sessionFormat: format))
            try assertUpright(result.output)
        }
    }

    /// JPEG -> JPEG was never visibly broken — cjpeg copies the orientation
    /// marker, so the output displayed correctly. It now goes through
    /// ImageIO instead, and this pins the outcome: same appearance, but
    /// upright in the pixels rather than by instruction.
    func testJPEGToJPEGIsBakedRatherThanForwarded() throws {
        let input = try staged("rotated", "jpg")
        let result = try makeEngine().shrink(input, settings: settings())
        XCTAssertEqual(result.output.pathExtension, "jpg")
        try assertUpright(result.output)
    }

    func testPNGToPNGComesOutUpright() throws {
        let input = try staged("rotated", "png")
        let result = try makeEngine().shrink(input, settings: settings())
        XCTAssertEqual(result.output.pathExtension, "png")
        try assertUpright(result.output)
    }

    /// Orientation is not governed by the metadata policy: stripping
    /// everything must still leave the image the right way up.
    func testOutputIsUprightUnderEveryMetadataPolicy() throws {
        let engine = try makeEngine()
        for policy in MetadataPolicy.allCases {
            let input = try staged("rotated", "heic")
            let result = try engine.shrink(input, settings: settings(policy: policy))
            try assertUpright(result.output)
        }
    }

    /// An upright file must be untouched by any of this — the common case
    /// should not acquire a rotation it never had.
    func testAnUprightFileIsLeftAlone() throws {
        let input = try staged("sample", "png")
        let result = try makeEngine().shrink(input, settings: settings())
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(result.output as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 548)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 547)
    }

    // MARK: - Metadata, end to end

    func testKeepAllCarriesMetadataAcrossAConversion() throws {
        let input = try staged("rotated", "heic")
        let result = try makeEngine().shrink(input, settings: settings(policy: .all))
        let properties = try propertiesOf(result.output)
        XCTAssertEqual(copyright(in: properties), "© 2026 Shrinker Pro Test",
                       "HEIC -> JPEG used to lose every trace of metadata")
        XCTAssertNotNil(latitude(in: properties))
    }

    func testStrippedRemovesMetadataFromAConvertedFile() throws {
        let input = try staged("rotated", "heic")
        let result = try makeEngine().shrink(input, settings: settings(policy: .stripped))
        let properties = try propertiesOf(result.output)
        XCTAssertNil(copyright(in: properties))
        XCTAssertNil(latitude(in: properties))
    }

    func testCopyrightOnlyKeepsRightsAndDropsGPSEndToEnd() throws {
        let input = try staged("rotated", "jpg")
        let result = try makeEngine().shrink(input, settings: settings(policy: .copyright))
        let properties = try propertiesOf(result.output)
        XCTAssertEqual(copyright(in: properties), "© 2026 Shrinker Pro Test")
        XCTAssertNil(latitude(in: properties), "GPS must not survive 'copyright and credit only'")
    }

    /// WebP has no post-pass available — its metadata can only arrive via
    /// cwebp's own flag — so it gets its own end-to-end check per policy.
    func testWebPHonoursTheMetadataPolicy() throws {
        let engine = try makeEngine()

        let kept = try engine.shrink(
            try staged("rotated", "jpg"), settings: settings(sessionFormat: .webp, policy: .all)
        )
        XCTAssertEqual(copyright(in: try propertiesOf(kept.output)), "© 2026 Shrinker Pro Test")

        let stripped = try engine.shrink(
            try staged("rotated", "jpg"), settings: settings(sessionFormat: .webp, policy: .stripped)
        )
        XCTAssertNil(copyright(in: try propertiesOf(stripped.output)))

        let rights = try engine.shrink(
            try staged("rotated", "jpg"), settings: settings(sessionFormat: .webp, policy: .copyright)
        )
        let properties = try propertiesOf(rights.output)
        XCTAssertEqual(copyright(in: properties), "© 2026 Shrinker Pro Test")
        XCTAssertNil(latitude(in: properties))
    }

    // MARK: - The session override

    func testTheSessionOverrideConvertsEveryRasterFormat() throws {
        let engine = try makeEngine()
        for (name, ext) in [("rotated", "heic"), ("rotated", "jpg"), ("rotated", "png")] {
            let result = try engine.shrink(
                try staged(name, ext), settings: settings(sessionFormat: .avif)
            )
            XCTAssertEqual(result.output.pathExtension, "avif", "\(ext) ignored the session override")
        }
    }

    /// The override must beat the stored rules, not merge with them.
    func testTheSessionOverrideBeatsTheStoredRules() throws {
        let rules = ConversionRules(png: .keep, jpeg: .keep, heic: .jpeg, webp: .keep, avif: .keep)
        let result = try makeEngine().shrink(
            try staged("rotated", "jpg"),
            settings: settings(sessionFormat: .webp, rules: rules)
        )
        XCTAssertEqual(result.output.pathExtension, "webp")
    }

    /// SVG and GIF are exempt — they short-circuit before any rule or
    /// override is consulted. Converting an animated GIF to a still image,
    /// or rasterising a vector, is never what a drop meant.
    func testSVGAndGIFIgnoreTheSessionOverride() throws {
        let engine = try makeEngine()
        for ext in ["svg", "gif"] {
            let result = try engine.shrink(
                try staged("sample", ext), settings: settings(sessionFormat: .jpeg)
            )
            XCTAssertEqual(result.output.pathExtension, ext,
                           "\(ext) must never be converted by the session override")
        }
    }

    func testNoOverrideLeavesTheStoredRulesInCharge() throws {
        let result = try makeEngine().shrink(
            try staged("rotated", "jpg"), settings: settings(sessionFormat: nil)
        )
        XCTAssertEqual(result.output.pathExtension, "jpg")
    }

    // MARK: - Helpers

    private func propertiesOf(_ url: URL) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private func copyright(in properties: [CFString: Any]) -> String? {
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        return (tiff?[kCGImagePropertyTIFFCopyright] as? String)
            ?? (iptc?[kCGImagePropertyIPTCCopyrightNotice] as? String)
    }

    private func latitude(in properties: [CFString: Any]) -> Any? {
        (properties[kCGImagePropertyGPSDictionary] as? [CFString: Any])?[kCGImagePropertyGPSLatitude]
    }
}
