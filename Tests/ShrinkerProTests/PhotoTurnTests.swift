import CoreGraphics
import XCTest
@testable import ShrinkerPro

/// The eight ways a photo can lie, which Rotate Left and Rotate Right compose.
final class PhotoTurnTests: XCTestCase {
    private static let all: [PhotoTurn] = (0..<4).flatMap { q in [false, true].map { PhotoTurn(quarters: q, mirrored: $0) } }

    func testTurnsComposeAndUndo() {
        XCTAssertEqual(PhotoTurn.identity.rotatedRight.rotatedRight.rotatedRight.rotatedRight, .identity)
        XCTAssertEqual(PhotoTurn.identity.rotatedRight.rotatedLeft, .identity)
        for turn in Self.all {
            XCTAssertEqual(turn.then(turn.inverse), .identity)
            XCTAssertEqual(turn.flippedHorizontally.flippedHorizontally, turn)
            XCTAssertEqual(turn.flippedHorizontally.flippedVertically, turn.rotatedHalf)
        }
    }

    func testSizesAndRectsFollowTheTurn() {
        XCTAssertEqual(PhotoTurn(quarters: 1).size(PixelSize(width: 300, height: 200)), PixelSize(width: 200, height: 300))
        XCTAssertEqual(PhotoTurn(quarters: 1).map(CGRect(x: 30, y: 40, width: 90, height: 80), in: CGSize(width: 300, height: 200)),
                       CGRect(x: 80, y: 30, width: 80, height: 90))
    }

    /// The top-left pixel lands where the turn takes the top-left corner, for every turn.
    func testPixelsLandWhereTheCornerGoes() throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 1, width: 1, height: 1))  // bottom-left origin: the top-left pixel
        let image = try XCTUnwrap(context.makeImage())
        for turn in Self.all {
            let out = try XCTUnwrap(turn.apply(to: image))
            var bytes = [UInt8](repeating: 0, count: out.width * out.height * 4)
            let read = try XCTUnwrap(CGContext(data: &bytes, width: out.width, height: out.height, bitsPerComponent: 8,
                                               bytesPerRow: out.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            read.draw(out, in: CGRect(x: 0, y: 0, width: out.width, height: out.height))
            let corner = turn.unitPoint(x: 0.125, y: 0.25)
            let x = Int(corner.x * Double(out.width)), y = Int(corner.y * Double(out.height))
            XCTAssertGreaterThan(bytes[(y * out.width + x) * 4], 200, "\(turn)")
        }
    }
}
