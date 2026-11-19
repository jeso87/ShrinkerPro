import XCTest
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import ShrinkerPro

/// Camera RAW, TIFF, Photoshop and BMP (`NativeFormat.other`): read by ImageIO, never written,
/// so like HEIC they always convert, to JPEG unless the rule or the session says otherwise.
///
/// TIFF, BMP and PSD are written here by ImageIO from the JPEG fixture. ImageIO can't write a
/// RAW file, so RAW is covered by the routing, which is the same route TIFF takes.
final class ReadOnlyFormatsTests: XCTestCase {

    private struct MissingTestResource: Error {}

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("readonly-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makeEngine() throws -> ShrinkEngine {
        let repoRoot = ProcessInfo.processInfo.environment["SRCROOT"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let vendor = repoRoot.appendingPathComponent("vendor/compressors")
        guard FileManager.default.isExecutableFile(atPath: vendor.appendingPathComponent("cjpeg").path) else {
            XCTFail("compressors not built — run scripts/build-compressors.sh")
            throw MissingTestResource()
        }
        let bundle = Bundle(for: ReadOnlyFormatsTests.self)
        guard let svgo = Bundle.main.url(forResource: "svgo.jsc", withExtension: "js")
            ?? bundle.url(forResource: "svgo.jsc", withExtension: "js") else {
            XCTFail("svgo.jsc.js not bundled — run scripts/prepare-svgo.sh, then xcodegen generate")
            throw MissingTestResource()
        }
        return try ShrinkEngine(helperProvider: { vendor.appendingPathComponent($0) }, svgoScriptURL: svgo)
    }

    /// The JPEG fixture re-written by ImageIO as `type`, under `name`.
    private func makeImage(_ name: String, type: UTType) throws -> URL {
        let bundle = Bundle(for: ReadOnlyFormatsTests.self)
        guard let jpeg = bundle.url(forResource: "sample", withExtension: "jpg", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "sample", withExtension: "jpg"),
              let source = CGImageSourceCreateWithURL(jpeg as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            XCTFail("sample.jpg fixture missing")
            throw MissingTestResource()
        }
        let url = scratch.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            XCTFail("ImageIO can't write \(type.identifier)")
            throw MissingTestResource()
        }
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func settings(rules: ConversionRules = ConversionRules(), session: SessionFormat? = nil) -> OutputSettings {
        OutputSettings(
            saveInSameFolder: true, savePath: nil, useSubfolder: false, keepOriginal: true,
            conversionRules: rules, sessionFormat: session
        )
    }

    private func decodes(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }

    // MARK: Accepted

    func testTheEngineAcceptsRAWTIFFPSDAndBMP() {
        for ext in ["tif", "tiff", "psd", "bmp", "dng", "cr3", "cr2", "nef", "arw", "raf", "orf", "rw2"] {
            XCTAssertTrue(ShrinkEngine.supportedExtensions.contains(ext), ext)
            XCTAssertEqual(NativeFormat(extension: ext), .other, ext)
        }
        let types = Set(ShrinkEngine.supportedContentTypes.map(\.identifier))
        for identifier in ["public.tiff", "com.microsoft.bmp", "com.adobe.photoshop-image", "public.camera-raw-image"] {
            XCTAssertTrue(types.contains(identifier), identifier)
        }
        // Every maker's RAW type conforms to the one supertype the open panel is given.
        XCTAssertTrue(UTType(filenameExtension: "dng")?.conforms(to: .rawImage) ?? false)
    }

    // MARK: Routing

    func testOtherAlwaysConvertsAndTakesTheHEICRoutes() {
        XCTAssertTrue(NativeFormat.other.alwaysConverts)
        XCTAssertTrue(NativeFormat.heic.alwaysConverts)
        XCTAssertFalse(NativeFormat.png.alwaysConverts)
        for target in TargetFormat.allCases {
            XCTAssertEqual(
                ConversionRouter.route(native: .other, target: target),
                ConversionRouter.route(native: .heic, target: target),
                "\(target): RAW, TIFF, PSD and BMP decode only through ImageIO, exactly like HEIC"
            )
        }
        // Rotated or resized makes no difference: every route out already starts with ImageIO.
        let rotated = RoutingContext(isUpright: false, policy: .copyright, needsPixelRework: true)
        XCTAssertEqual(ConversionRouter.route(native: .other, rule: ConversionFormat.webp, context: rotated),
                       .viaIntermediate(target: .webp, intermediate: .png))
    }

    func testTheRuleDefaultsToJPEGAndHasNoKeep() {
        XCTAssertEqual(ConversionRules().other, .jpeg)
    }

    func testTheNeverGrowGuardLeavesConversionsOutOfThemAlone() {
        for ext in ["tiff", "psd", "bmp", "dng", "cr3"] {
            XCTAssertFalse(ShrinkEngine.guardsGrowth(ofConversionFrom: ext, to: "webp", isSameFormat: false), ext)
        }
        XCTAssertTrue(ShrinkEngine.guardsGrowth(ofConversionFrom: "png", to: "webp", isSameFormat: false))
    }

    // MARK: End to end

    func testTIFFBMPAndPSDBecomeJPEGByDefault() throws {
        let engine = try makeEngine()
        for (name, type) in [("scan.tiff", UTType.tiff), ("paint.bmp", UTType.bmp),
                             ("layers.psd", UTType("com.adobe.photoshop-image")!)] {
            let input = try makeImage(name, type: type)
            let result = try engine.shrink(input, settings: settings())
            XCTAssertEqual(result.output.pathExtension, "jpg", name)
            XCTAssertEqual(Array(try Data(contentsOf: result.output).prefix(3)), [0xFF, 0xD8, 0xFF], "\(name): not a JPEG")
            XCTAssertTrue(decodes(result.output), name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: input.path), "\(name): original touched")
        }
    }

    func testTheRuleAndTheSessionChooseTheFormat() throws {
        let engine = try makeEngine()
        let tiff = try makeImage("scan.tif", type: .tiff)

        let webp = try engine.shrink(tiff, settings: settings(rules: ConversionRules(other: .webp)))
        XCTAssertEqual(webp.output.lastPathComponent, "scan.min.webp")
        XCTAssertTrue(decodes(webp.output))

        let png = try engine.shrink(tiff, settings: settings(session: .png))
        XCTAssertEqual(png.output.lastPathComponent, "scan.min.png")
        XCTAssertTrue(decodes(png.output))
    }

    // MARK: Settings and the command line

    @MainActor
    func testTheRulePersists() {
        let defaults = makeTestDefaults()
        XCTAssertEqual(Settings(defaults: defaults).otherConversion, .jpeg)
        let first = Settings(defaults: defaults)
        first.otherConversion = .avif
        XCTAssertEqual(Settings(defaults: defaults).otherConversion, .avif)
        XCTAssertEqual(Settings(defaults: defaults).outputSettings.conversionRules.other, .avif)
    }

    func testTheCommandLineNamesThemJPEG() {
        XCTAssertEqual(OutputCollision.outputName(for: URL(fileURLWithPath: "/a/shot.CR3"), convertingTo: nil), "shot.min.jpg")
        XCTAssertEqual(OutputCollision.outputName(for: URL(fileURLWithPath: "/a/scan.tiff"), convertingTo: .webp), "scan.min.webp")
        // shot.dng and shot.jpg both land on shot.min.jpg, so a run with both is caught.
        let clash = OutputCollision.groups(in: [URL(fileURLWithPath: "/a/shot.dng"), URL(fileURLWithPath: "/a/shot.jpg")], convertingTo: nil)
        XCTAssertEqual(clash.map(\.name), ["shot.min.jpg"])
    }
}
