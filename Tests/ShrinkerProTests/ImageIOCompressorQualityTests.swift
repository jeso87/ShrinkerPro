import XCTest
@testable import ShrinkerPro

/// macOS 27's AVIF encoder refuses a lossy-compression quality of exactly 1.0 (the top of
/// every quality scale, and the first probe of a "looks the same" search), so ImageIO's
/// finalize fails. Anything below 1.0 encodes.
final class ImageIOCompressorQualityTests: XCTestCase {
    func testAVIFAtTopQualityEncodes() throws {
        let bundle = Bundle(for: Self.self)
        let source = try XCTUnwrap(bundle.url(forResource: "sample", withExtension: "jpg", subdirectory: "Fixtures"))
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("top-quality-\(UUID().uuidString).avif")
        defer { try? FileManager.default.removeItem(at: output) }

        try ImageIOCompressor(utType: "public.avif", quality: 1.0).compress(input: source, output: output)

        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int)
        XCTAssertGreaterThan(size, 0)
    }

    func testOnlyAVIFAtTheTopIsHeldBelowIt() {
        XCTAssertLessThan(ImageIOCompressor.encoderQuality(1.0, utType: "public.avif"), 1.0)
        XCTAssertEqual(ImageIOCompressor.encoderQuality(0.8, utType: "public.avif"), 0.8)
        XCTAssertEqual(ImageIOCompressor.encoderQuality(1.0, utType: "public.heic"), 1.0)
    }
}
