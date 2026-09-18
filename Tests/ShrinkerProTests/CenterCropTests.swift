import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ShrinkerPro

/// The center crop, end to end through the real engine and the real vendored
/// encoders.
///
/// `CropGeometryTests` proves the rectangle is right; this proves the
/// rectangle reaches the pixels — through five still formats, three of whose
/// encoders cannot crop and are therefore relayed through ImageIO to get here,
/// and through gifsicle for GIF.
///
/// See `2026-09-17-center-crop-design.md`.
final class CenterCropTests: XCTestCase {

    // MARK: - Fixtures and helpers

    private struct MissingTestResource: Error {}

    private func vendorCompressorsRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath)
        while dir.pathComponents.count > 1 {
            dir.deleteLastPathComponent()
            let candidate = dir.appendingPathComponent("vendor/compressors")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("cjpeg").path) {
                return candidate
            }
        }
        XCTFail("vendor/compressors not found — run scripts/build-compressors.sh")
        throw MissingTestResource()
    }

    private func makeEngine() throws -> ShrinkEngine {
        let bundle = Bundle(for: CenterCropTests.self)
        guard let svgo = Bundle.main.url(forResource: "svgo.jsc", withExtension: "js")
            ?? bundle.url(forResource: "svgo.jsc", withExtension: "js") else {
            XCTFail("svgo.jsc.js not bundled — run scripts/prepare-svgo.sh, then xcodegen generate")
            throw MissingTestResource()
        }
        let vendor = try vendorCompressorsRoot()
        return try ShrinkEngine(
            helperProvider: { vendor.appendingPathComponent($0) }, svgoScriptURL: svgo
        )
    }

    private func stagedFixture(_ name: String, _ ext: String) throws -> URL {
        let bundle = Bundle(for: CenterCropTests.self)
        guard let source = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: ext) else {
            XCTFail("fixture \(name).\(ext) not found in test bundle")
            throw MissingTestResource()
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let staged = dir.appendingPathComponent("\(name).\(ext)")
        try FileManager.default.copyItem(at: source, to: staged)
        return staged
    }

    /// Measured from the finished file, oriented — the size a viewer sees, and
    /// therefore the size the crop is a promise about.
    private func size(of url: URL) -> CGSize? {
        ImageMetadata.header(of: url).pixelSize
    }

    private func frameCount(of url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 0 }
        return CGImageSourceGetCount(source)
    }

    private func settings(
        crop: CropTarget? = nil, maxDimension: Int? = nil
    ) -> OutputSettings {
        OutputSettings(
            saveInSameFolder: true, savePath: nil, useSubfolder: false, keepOriginal: true,
            maxDimension: maxDimension, cropTarget: crop
        )
    }

    private func pixels(_ w: Int, _ h: Int) -> CropTarget {
        CropTarget(width: w, height: h, mode: .pixels)
    }

    private func ratio(_ w: Int, _ h: Int) -> CropTarget {
        CropTarget(width: w, height: h, mode: .ratio)
    }

    // MARK: - The size and the shape

    /// Every raster format, including the three whose encoders cannot crop and
    /// are relayed through ImageIO to get here. Pixel mode is a promise about
    /// exact numbers, so this asserts them exactly rather than with a
    /// tolerance.
    func testEveryRasterFormatIsCroppedToAnExactSize() throws {
        let engine = try makeEngine()
        for ext in ["jpg", "png", "webp", "avif", "heic"] {
            let input = try stagedFixture("sample", ext)
            defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }

            let result = try engine.shrink(input, settings: settings(crop: pixels(200, 200)))

            let output = try XCTUnwrap(size(of: result.output), "\(ext): output declares no size")
            XCTAssertEqual(output.width, 200, "\(ext): width")
            XCTAssertEqual(output.height, 200, "\(ext): height")
        }
    }

    /// A non-square exact size, so that a crop which happened to be square by
    /// accident could not pass the test above and this one both.
    func testANonSquareExactSizeIsHonouredOnEveryRoute() throws {
        let engine = try makeEngine()
        for ext in ["jpg", "png", "webp", "avif", "heic"] {
            let input = try stagedFixture("sample", ext)
            defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }

            let result = try engine.shrink(input, settings: settings(crop: pixels(320, 180)))

            let output = try XCTUnwrap(size(of: result.output), "\(ext)")
            XCTAssertEqual(output.width, 320, "\(ext): width")
            XCTAssertEqual(output.height, 180, "\(ext): height")
        }
    }

    /// Ratio mode changes the shape and leaves the resolution alone. The
    /// 548×547 fixture cropped square keeps its shorter side.
    func testRatioModeCropsTheShapeAndKeepsTheResolution() throws {
        let engine = try makeEngine()
        for ext in ["jpg", "png", "webp", "avif", "heic"] {
            let input = try stagedFixture("sample", ext)
            defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }

            let result = try engine.shrink(input, settings: settings(crop: ratio(1, 1)))

            let output = try XCTUnwrap(size(of: result.output), "\(ext)")
            XCTAssertEqual(output.width, 547, "\(ext): width")
            XCTAssertEqual(output.height, 547, "\(ext): height")
        }
    }

    /// **Nothing is ever enlarged.** A 200×100 source asked for 1200×1200
    /// comes out 100×100 — the right shape, smaller than asked. This is the
    /// rule that makes a mixed batch come out non-uniform, which is the
    /// opposite of what a fixed crop is usually for, so it is asserted rather
    /// than assumed.
    func testASourceTooSmallIsCroppedButNeverEnlarged() throws {
        let engine = try makeEngine()
        for ext in ["jpg", "png", "heic"] {
            let input = try stagedFixture("rotated", ext)
            defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }

            let result = try engine.shrink(input, settings: settings(crop: pixels(1200, 1200)))

            let output = try XCTUnwrap(size(of: result.output), "\(ext)")
            XCTAssertEqual(output.width, 100, "\(ext): width")
            XCTAssertEqual(output.height, 100, "\(ext): height")
        }
    }

    // MARK: - Orientation

    /// **The shape is applied to the axes a viewer sees, not to the stored
    /// buffer.** The `rotated` fixtures store a portrait buffer with a
    /// rotation tag and read as 200×100 landscape.
    ///
    /// Computing the crop against the stored buffer would take a 16:9
    /// rectangle out of a portrait image and hand back something that is 9:16
    /// once the rotation is applied — the requested shape in the file and the
    /// wrong shape on screen. Both results are rectangles of plausible size,
    /// so nothing but this assertion would notice.
    ///
    /// Named so that nobody later "fixes" the literal application of the
    /// target: see `2026-09-17-center-crop-design.md` §1 and §4.
    func testARotatedSourceIsCroppedOnTheAxesAViewerSees() throws {
        let engine = try makeEngine()
        for ext in ["jpg", "png", "heic"] {
            let input = try stagedFixture("rotated", ext)
            defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }
            let original = try XCTUnwrap(size(of: input), "\(ext)")
            XCTAssertGreaterThan(
                original.height, original.width,
                "\(ext): the fixture must read portrait for this test to mean anything"
            )

            let result = try engine.shrink(input, settings: settings(crop: ratio(16, 9)))

            let output = try XCTUnwrap(size(of: result.output), "\(ext)")
            XCTAssertGreaterThan(
                output.width, output.height,
                "\(ext): a 16:9 crop came out portrait — the shape was applied to the stored buffer"
            )
            XCTAssertEqual(
                output.width / output.height, 16.0 / 9.0, accuracy: 0.02,
                "\(ext): \(output) is not 16:9"
            )
        }
    }

    /// The same fixture cropped square, which a wrong-axis implementation
    /// would also pass — included so the pair makes clear that the previous
    /// test's asymmetry is the point.
    func testARotatedSourceCroppedSquareIsSquare() throws {
        let engine = try makeEngine()
        let input = try stagedFixture("rotated", "png")
        defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }

        let result = try engine.shrink(input, settings: settings(crop: ratio(1, 1)))

        let output = try XCTUnwrap(size(of: result.output))
        XCTAssertEqual(output.width, 100)
        XCTAssertEqual(output.height, 100)
    }

    // MARK: - Where the rectangle is taken from

    /// **The crop really is taken from the center**, proved on a generated
    /// image rather than a photograph so the assertion can be exact: three
    /// vertical bands, red | green | blue, where the green band is precisely
    /// the square a 1:1 crop should select.
    ///
    /// Everything else in this suite would pass on a crop anchored top-left;
    /// this is the test that would not.
    func testTheCropIsTakenFromTheCenterHorizontally() throws {
        let engine = try makeEngine()
        let input = try bandedImage(
            width: 400, height: 200, vertical: false, named: "bands-h"
        )
        defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }

        let result = try engine.shrink(input, settings: settings(crop: ratio(1, 1)))

        let output = try XCTUnwrap(size(of: result.output))
        XCTAssertEqual(output.width, 200)
        XCTAssertEqual(output.height, 200)
        try assertIsEntirelyGreen(result.output, "a 1:1 crop of red|green|blue bands")
    }

    /// The vertical twin, so neither axis can be centered by accident while
    /// the other is anchored.
    func testTheCropIsTakenFromTheCenterVertically() throws {
        let engine = try makeEngine()
        let input = try bandedImage(
            width: 200, height: 400, vertical: true, named: "bands-v"
        )
        defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }

        let result = try engine.shrink(input, settings: settings(crop: ratio(1, 1)))

        let output = try XCTUnwrap(size(of: result.output))
        XCTAssertEqual(output.width, 200)
        XCTAssertEqual(output.height, 200)
        try assertIsEntirelyGreen(result.output, "a 1:1 crop of stacked red|green|blue bands")
    }

    // MARK: - Composition with the max size

    /// **A pixel crop ignores the max size entirely**, even one asking for
    /// less. The two are answers to one question and the crop is the more
    /// specific: there is no size a cap could impose that smaller numbers in
    /// the crop would not state better.
    ///
    /// Composing them was tried first, and produced 100×100 here — correct
    /// arithmetic, and a file the size of neither thing the user typed. It
    /// needed a warning in the window to be survivable, and a warning about
    /// two controls fighting is a sign one of them should not be there. Both
    /// front ends now refuse the pair instead: the window disables the field,
    /// and `--crop WxH` with `--max-size` is a parse error.
    func testAPixelCropIgnoresTheMaxSize() throws {
        let engine = try makeEngine()
        let input = try stagedFixture("sample", "png")
        defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }

        let result = try engine.shrink(
            input, settings: settings(crop: pixels(400, 400), maxDimension: 100)
        )

        let output = try XCTUnwrap(size(of: result.output))
        XCTAssertEqual(output.width, 400, "the cap overruled an exact crop")
        XCTAssertEqual(output.height, 400)
    }

    /// A ratio crop with a cap: the shape comes from the crop, the size from
    /// the cap.
    func testARatioCropAndACapCompose() throws {
        let engine = try makeEngine()
        let input = try stagedFixture("sample", "png")
        defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }

        let result = try engine.shrink(
            input, settings: settings(crop: ratio(2, 1), maxDimension: 300)
        )

        let output = try XCTUnwrap(size(of: result.output))
        XCTAssertEqual(max(output.width, output.height), 300, accuracy: 1)
        XCTAssertEqual(output.width / output.height, 2, accuracy: 0.02)
    }

    /// And the other way round: a cap that asks for more than the crop changes
    /// nothing, so the exact size is still exact.
    func testACapLargerThanTheCropLeavesTheExactSizeAlone() throws {
        let engine = try makeEngine()
        let input = try stagedFixture("sample", "png")
        defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }

        let result = try engine.shrink(
            input, settings: settings(crop: pixels(200, 200), maxDimension: 5000)
        )

        let output = try XCTUnwrap(size(of: result.output))
        XCTAssertEqual(output.width, 200)
        XCTAssertEqual(output.height, 200)
    }

    // MARK: - GIF

    /// GIF is cropped by gifsicle rather than ImageIO, and this is why: an
    /// ImageIO round trip writes one frame, so the animation would arrive at
    /// the user as a still. A passing dimension check alone would not notice.
    func testAnimatedGIFKeepsEveryFrameWhenCropped() throws {
        let engine = try makeEngine()
        let input = try stagedFixture("sample", "gif")
        defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }

        let framesBefore = frameCount(of: input)
        XCTAssertGreaterThan(framesBefore, 1, "the fixture must be animated for this to mean anything")

        let result = try engine.shrink(input, settings: settings(crop: ratio(16, 9)))

        let output = try XCTUnwrap(size(of: result.output))
        XCTAssertEqual(output.width, 120)
        XCTAssertEqual(output.height, 68)
        XCTAssertEqual(
            frameCount(of: result.output), framesBefore,
            "the animation was flattened by the crop"
        )
    }

    func testAGIFIsCroppedToAnExactSize() throws {
        let engine = try makeEngine()
        let input = try stagedFixture("sample", "gif")
        defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }

        let result = try engine.shrink(input, settings: settings(crop: pixels(60, 40)))

        let output = try XCTUnwrap(size(of: result.output))
        XCTAssertEqual(output.width, 60)
        XCTAssertEqual(output.height, 40)
        XCTAssertEqual(frameCount(of: result.output), 12)
    }

    /// **The case `--unoptimize` exists for.** `offsetframes.gif` has a 300×300
    /// logical screen whose frames are 120×120 at (10,10), which is what an
    /// optimised GIF looks like.
    ///
    /// gifsicle measures `--crop` against the bounding box of the input frames
    /// rather than the logical screen, so without unoptimising first this
    /// silently produced a 130×65 file and exited 0 — a wrong-sized result that
    /// no error would have reported. See
    /// `2026-09-17-center-crop-design.md` §6.
    func testAnOptimisedGIFWithOffsetFramesIsStillCroppedExactly() throws {
        let engine = try makeEngine()
        let input = try stagedFixture("offsetframes", "gif")
        defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }

        let original = try XCTUnwrap(size(of: input))
        XCTAssertEqual(original.width, 300, "fixture must declare the logical screen")
        let framesBefore = frameCount(of: input)

        let result = try engine.shrink(input, settings: settings(crop: ratio(16, 9)))

        let output = try XCTUnwrap(size(of: result.output))
        XCTAssertEqual(output.width, 300, "the crop was measured against the frames, not the screen")
        XCTAssertEqual(output.height, 169)
        XCTAssertEqual(frameCount(of: result.output), framesBefore)
    }

    /// And the case that used to fail outright rather than quietly: a crop
    /// whose rectangle sits well outside the frames' bounding box.
    func testAnOptimisedGIFSurvivesACropNearItsEdges() throws {
        let engine = try makeEngine()
        let input = try stagedFixture("offsetframes", "gif")
        defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }

        let result = try engine.shrink(input, settings: settings(crop: pixels(280, 40)))

        // Exactly 280×40, not the 279×40 that `--resize-fit` produced before
        // the flag was split — see `GIFCompressor`.
        let output = try XCTUnwrap(size(of: result.output))
        XCTAssertEqual(output.width, 280)
        XCTAssertEqual(output.height, 40)
        // Frame count is deliberately not asserted here. This band is almost
        // entirely background, so every frame in it is pixel-identical and
        // `-O=2` — which has been in the argv since long before cropping —
        // correctly merges them into one. That is the optimiser doing its job
        // losslessly, not the animation being flattened; the tests above cover
        // the case where there is motion to preserve.
    }

    // MARK: - What the plan says

    func testSVGIgnoresTheCrop() throws {
        let engine = try makeEngine()
        let input = try stagedFixture("sample", "svg")
        defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }

        let plan = try engine.plan(input, settings: settings(crop: pixels(10, 10)))

        XCTAssertFalse(plan.dimensionsChanged, "a vector has no pixels to cut")
    }

    /// The flag the never-grow guard reads, on every route — including the
    /// relayed ones, whose non-nil `targetExtension` makes them look like
    /// conversions.
    func testThePlanReportsCroppingOnEveryRoute() throws {
        let engine = try makeEngine()
        for ext in ["jpg", "png", "webp", "avif", "heic", "gif"] {
            let input = try stagedFixture("sample", ext)
            defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }

            XCTAssertTrue(
                try engine.plan(input, settings: settings(crop: ratio(16, 9))).dimensionsChanged,
                "\(ext): a 16:9 crop of a near-square image changes its dimensions"
            )
        }
    }

    /// A source already the target shape is not reworked at all. Re-encoding
    /// it at its own size would cost quality for no change in dimensions —
    /// the same exemption a file whose longest side equals the cap gets.
    func testASourceAlreadyTheTargetShapeIsNotReworked() throws {
        let engine = try makeEngine()
        let input = try bandedImage(width: 300, height: 300, vertical: false, named: "square")
        defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }

        let plan = try engine.plan(input, settings: settings(crop: ratio(1, 1)))

        XCTAssertFalse(plan.dimensionsChanged, "a square image cropped square has nothing to do")
    }

    /// **Off costs nothing.** With no crop and no cap, every field of the plan
    /// is what it was before either setting existed. This is the regression net
    /// for §2's promise, and it is why the sizing decision guards before it
    /// reads a single dimension.
    func testAnUnsetCropLeavesThePlanExactlyAsItWas() throws {
        let engine = try makeEngine()
        for ext in ["jpg", "png", "webp", "avif", "heic", "gif", "svg"] {
            let input = try stagedFixture("sample", ext)
            defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }

            let plan = try engine.plan(input, settings: settings(crop: nil, maxDimension: nil))

            XCTAssertFalse(plan.dimensionsChanged, "\(ext)")
        }
    }

    // MARK: - Generated fixtures

    /// A PNG of three equal-ish bands — red, green, blue — where the green band
    /// is exactly the square that a centered 1:1 crop should select.
    ///
    /// Generated rather than committed because the assertion is about
    /// *position*, and a photograph cannot say where its own center is.
    private func bandedImage(
        width: Int, height: Int, vertical: Bool, named: String
    ) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(named).png")

        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("could not create a context for the generated fixture")
            throw MissingTestResource()
        }

        let short = vertical ? width : height
        let long = vertical ? height : width
        let band = (long - short) / 2

        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        if band > 0 {
            if vertical {
                context.fill(CGRect(x: 0, y: 0, width: width, height: band))
                context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: height - band, width: width, height: band))
            } else {
                context.fill(CGRect(x: 0, y: 0, width: band, height: height))
                context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
                context.fill(CGRect(x: width - band, y: 0, width: band, height: height))
            }
        }

        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil
              )
        else {
            XCTFail("could not write the generated fixture")
            throw MissingTestResource()
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            XCTFail("could not finalise the generated fixture")
            throw MissingTestResource()
        }
        return url
    }

    /// Every pixel of `url` is green, within the tolerance a lossy encoder and
    /// a resample need. Sampled on a grid rather than exhaustively, and
    /// deliberately including the corners, which are the first thing an
    /// off-center crop would get wrong.
    private func assertIsEntirelyGreen(
        _ url: URL, _ what: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            XCTFail("\(what): could not decode the output", file: file, line: line)
            return
        }
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("\(what): could not read the output's pixels", file: file, line: line)
            return
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        for yStep in 0...8 {
            for xStep in 0...8 {
                let x = min(width - 1, xStep * (width - 1) / 8)
                let y = min(height - 1, yStep * (height - 1) / 8)
                let offset = (y * width + x) * 4
                let r = Int(bytes[offset]), g = Int(bytes[offset + 1]), b = Int(bytes[offset + 2])
                XCTAssertGreaterThan(
                    g, 160, "\(what): pixel at \(x),\(y) is not green — rgb(\(r),\(g),\(b))",
                    file: file, line: line
                )
                XCTAssertLessThan(
                    r, 96, "\(what): pixel at \(x),\(y) has red in it — rgb(\(r),\(g),\(b))",
                    file: file, line: line
                )
                XCTAssertLessThan(
                    b, 96, "\(what): pixel at \(x),\(y) has blue in it — rgb(\(r),\(g),\(b))",
                    file: file, line: line
                )
            }
        }
    }
}
