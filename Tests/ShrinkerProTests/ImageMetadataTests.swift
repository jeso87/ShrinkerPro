import XCTest
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import ShrinkerPro

final class ImageMetadataTests: XCTestCase {

    private struct MissingTestResource: Error {}

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        let bundle = Bundle(for: ImageMetadataTests.self)
        guard let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: ext) else {
            XCTFail("fixture \(name).\(ext) not found — regenerate with scripts/make-orientation-fixtures.swift, then xcodegen generate")
            throw MissingTestResource()
        }
        return url
    }

    private func scratchDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("metadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: - Orientation

    func testOrientationIsReadFromTheFile() throws {
        XCTAssertEqual(ImageMetadata.orientation(of: try fixture("rotated", "jpg")), .right)
        XCTAssertEqual(ImageMetadata.orientation(of: try fixture("rotated", "heic")), .right)
    }

    func testOrientationDefaultsToUpForAnUntaggedFile() throws {
        XCTAssertEqual(ImageMetadata.orientation(of: try fixture("sample", "png")), .up)
    }

    func testOrientationOfAnUnreadableFileIsUpRatherThanACrash() throws {
        let missing = try scratchDirectory().appendingPathComponent("nope.jpg")
        XCTAssertEqual(ImageMetadata.orientation(of: missing), .up)
    }

    // MARK: - The bake

    /// The load-bearing test for the whole rotation fix.
    ///
    /// Every one of the eight orientations is checked against ImageIO's own
    /// `kCGImageSourceCreateThumbnailWithTransform`, which is the platform's
    /// answer to "what should this look like upright". Dimensions alone are
    /// not enough: they cannot tell a 90° clockwise turn from a 90°
    /// counter-clockwise one, which is exactly the mistake a hand-derived
    /// transform matrix makes. So this compares the four quadrants too.
    func testBakingMatchesImageIOForAllEightOrientations() throws {
        let marker = try makeMarker(width: 200, height: 100)
        let directory = try scratchDirectory()

        for raw in UInt32(1)...8 {
            let orientation = try XCTUnwrap(CGImagePropertyOrientation(rawValue: raw))
            let url = directory.appendingPathComponent("o\(raw).png")
            try write(marker, to: url, orientation: raw)

            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let truth = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 400,
            ] as CFDictionary), "ImageIO would not produce a transformed thumbnail for orientation \(raw)")

            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let baked = try XCTUnwrap(ImageMetadata.applyingOrientation(decoded, orientation))

            XCTAssertEqual(baked.width, truth.width, "width for orientation \(raw)")
            XCTAssertEqual(baked.height, truth.height, "height for orientation \(raw)")
            XCTAssertEqual(
                quadrants(of: baked), quadrants(of: truth),
                "orientation \(raw) came out turned the wrong way"
            )
        }
    }

    func testBakingAnUprightImageReturnsItUntouched() throws {
        let marker = try makeMarker(width: 200, height: 100)
        let baked = try XCTUnwrap(ImageMetadata.applyingOrientation(marker, .up))
        XCTAssertEqual(baked.width, 200)
        XCTAssertEqual(baked.height, 100)
        XCTAssertEqual(quadrants(of: baked), "RGBW")
    }

    func testBakingSwapsDimensionsForAQuarterTurn() throws {
        let marker = try makeMarker(width: 200, height: 100)
        let baked = try XCTUnwrap(ImageMetadata.applyingOrientation(marker, .right))
        XCTAssertEqual(baked.width, 100)
        XCTAssertEqual(baked.height, 200)
    }

    // MARK: - Policy

    func testKeepAllKeepsEverythingButOrientation() throws {
        let rewritten = try rewrite(try fixture("rotated", "jpg"), policy: .all)
        let properties = try propertiesOf(rewritten)

        XCTAssertNil(properties[kCGImagePropertyOrientation], "orientation must never survive")
        XCTAssertEqual(copyright(in: properties), "© 2026 Shrinker Pro Test")
        XCTAssertNotNil(captureDate(in: properties), "capture time should survive .all")
        XCTAssertNotNil(latitude(in: properties), "GPS should survive .all")
    }

    func testCopyrightOnlyKeepsRightsAndDropsLocationAndCaptureTime() throws {
        let rewritten = try rewrite(try fixture("rotated", "jpg"), policy: .copyright)
        let properties = try propertiesOf(rewritten)

        XCTAssertNil(properties[kCGImagePropertyOrientation])
        XCTAssertEqual(copyright(in: properties), "© 2026 Shrinker Pro Test")
        XCTAssertNil(captureDate(in: properties), "capture time must be dropped by .copyright")
        XCTAssertNil(latitude(in: properties), "GPS must be dropped by .copyright — this is the privacy case")
    }

    func testStrippedKeepsNothing() throws {
        let rewritten = try rewrite(try fixture("rotated", "jpg"), policy: .stripped)
        let properties = try propertiesOf(rewritten)

        XCTAssertNil(properties[kCGImagePropertyOrientation])
        XCTAssertNil(copyright(in: properties))
        XCTAssertNil(captureDate(in: properties))
        XCTAssertNil(latitude(in: properties))
    }

    /// The post-pass exists to apply a policy without undoing the work the
    /// vendored encoders were run to do. If it re-encoded, the pixels would
    /// change — so this asserts they don't, for all three policies.
    func testThePostPassNeverReEncodesThePixels() throws {
        let original = try fixture("rotated", "jpg")
        let before = try pixelData(of: original)
        for policy in MetadataPolicy.allCases {
            let rewritten = try rewrite(original, policy: policy)
            XCTAssertEqual(
                try pixelData(of: rewritten), before,
                "\(policy.rawValue) re-encoded the image instead of only rewriting its metadata"
            )
        }
    }

    /// Without `kCGImageMetadataShouldExcludeXMP`, ImageIO writes a padded
    /// XMP packet that added ~2.3KB to a 1.4KB file — a compressor making
    /// files bigger while reporting a saving. Stripping everything must
    /// never produce a larger file than it started with.
    func testStrippingMetadataDoesNotGrowTheFile() throws {
        let original = try fixture("rotated", "jpg")
        let rewritten = try rewrite(original, policy: .stripped)
        let before = try Data(contentsOf: original).count
        let after = try Data(contentsOf: rewritten).count
        XCTAssertLessThanOrEqual(after, before, "stripping metadata grew the file from \(before) to \(after) bytes")
    }

    func testUTTypeIsOnlyOfferedForFormatsImageIOCanWrite() {
        XCTAssertEqual(ImageMetadata.utType(forOutputExtension: "jpg"), "public.jpeg")
        XCTAssertEqual(ImageMetadata.utType(forOutputExtension: "JPEG"), "public.jpeg")
        XCTAssertEqual(ImageMetadata.utType(forOutputExtension: "png"), "public.png")
        // WebP is the case that matters: ImageIO cannot write it, so a
        // post-pass must never be attempted on one.
        XCTAssertNil(ImageMetadata.utType(forOutputExtension: "webp"))
        XCTAssertNil(ImageMetadata.utType(forOutputExtension: "avif"))
        XCTAssertNil(ImageMetadata.utType(forOutputExtension: "gif"))
    }

    // MARK: - Helpers

    private func rewrite(_ original: URL, policy: MetadataPolicy) throws -> URL {
        let directory = try scratchDirectory()
        let copy = directory.appendingPathComponent("copy.jpg")
        try FileManager.default.copyItem(at: original, to: copy)
        try ImageMetadata.rewriteMetadata(
            of: copy, takingFrom: original, policy: policy,
            utType: "public.jpeg", wasRotated: true, workingIn: directory
        )
        return copy
    }

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

    private func captureDate(in properties: [CFString: Any]) -> String? {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        return exif?[kCGImagePropertyExifDateTimeOriginal] as? String
    }

    private func latitude(in properties: [CFString: Any]) -> Any? {
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        return gps?[kCGImagePropertyGPSLatitude]
    }

    private func pixelData(of url: URL) throws -> Data {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try XCTUnwrap(image.dataProvider?.data as Data?)
    }

    private func makeMarker(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let w = CGFloat(width) / 2
        let h = CGFloat(height) / 2
        let quadrants: [(CGFloat, CGFloat, CGColor)] = [
            (0, h, CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
            (w, h, CGColor(red: 0, green: 1, blue: 0, alpha: 1)),
            (0, 0, CGColor(red: 0, green: 0, blue: 1, alpha: 1)),
            (w, 0, CGColor(red: 1, green: 1, blue: 1, alpha: 1)),
        ]
        for (x, y, color) in quadrants {
            context.setFillColor(color)
            context.fill(CGRect(x: x, y: y, width: w, height: h))
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func write(_ image: CGImage, to url: URL, orientation: UInt32) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(
            destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    /// The four corner colours, clockwise from top-left, read from a
    /// canonical 8-bit RGBA redraw.
    ///
    /// The redraw is not incidental: sampling a CGImage's own buffer
    /// directly depends on whatever pixel layout that particular image
    /// happens to use, and ImageIO's thumbnails and CoreGraphics' contexts
    /// do not agree on one. Comparing two images read that way produces
    /// confident nonsense.
    private func quadrants(of image: CGImage) -> String {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return "????" }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let redrawn = context.makeImage(),
              let data = redrawn.dataProvider?.data as Data? else { return "????" }

        func colour(_ x: Int, _ y: Int) -> String {
            let offset = y * width * 4 + x * 4
            guard offset + 2 < data.count else { return "?" }
            let pixel = (Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]))
            let references: [(String, (Int, Int, Int))] = [
                ("R", (255, 0, 0)), ("G", (0, 255, 0)), ("B", (0, 0, 255)), ("W", (255, 255, 255)),
            ]
            return references.min {
                distance(pixel, $0.1) < distance(pixel, $1.1)
            }?.0 ?? "?"
        }
        return colour(width / 4, height / 4) + colour(3 * width / 4, height / 4)
            + colour(width / 4, 3 * height / 4) + colour(3 * width / 4, 3 * height / 4)
    }

    private func distance(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int {
        let dr = a.0 - b.0, dg = a.1 - b.1, db = a.2 - b.2
        return dr * dr + dg * dg + db * db
    }
}
