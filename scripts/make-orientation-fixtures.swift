import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Writes the test fixtures used to prove that rotation is baked into the
// pixels rather than left to an orientation tag.
//
// The existing sample.png/jpg/heic fixtures cannot show this bug at all:
// they are 548x547 — so a 90° turn barely changes the dimensions — and
// carry orientation 0. A fixture for this job has to be
//
//   * clearly non-square, so a rotation is visible in width and height, and
//   * asymmetric in both axes, so a rotation the *wrong way* is visible too
//     (a left/right split alone cannot tell 90° clockwise from 90° counter-
//     clockwise once the dimensions match), and
//   * carrying real metadata of every kind the policy has to sort between —
//     rights, capture time, and GPS.
//
// Hence a 200x100 image of four solid quadrants, tagged orientation 6
// ("rotate 90° clockwise to display"), which displays as 100x200.
//
// Regenerate with:
//   swift scripts/make-orientation-fixtures.swift Tests/ShrinkerProTests/Fixtures

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(
        "usage: make-orientation-fixtures.swift <fixtures-dir>\n".data(using: .utf8)!
    )
    exit(2)
}
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])

/// Quadrants, as *displayed* once the orientation has been applied:
/// top-left red, top-right green, bottom-left blue, bottom-right white.
func marker(width: Int, height: Int) -> CGImage {
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { fatalError("could not create the drawing context") }

    let w = CGFloat(width) / 2
    let h = CGFloat(height) / 2
    // CGContext's origin is bottom-left, so the top row is drawn at y = h.
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
    guard let image = context.makeImage() else { fatalError("could not render the marker") }
    return image
}

let properties: [CFString: Any] = [
    // 6 = "rotate 90° clockwise to display".
    kCGImagePropertyOrientation: 6,
    kCGImagePropertyTIFFDictionary: [
        kCGImagePropertyTIFFCopyright: "© 2026 Shrinker Pro Test",
        kCGImagePropertyTIFFArtist: "Fixture Generator",
        kCGImagePropertyTIFFMake: "FixtureCam",
    ],
    kCGImagePropertyExifDictionary: [
        kCGImagePropertyExifDateTimeOriginal: "2026:01:02 03:04:05",
        kCGImagePropertyExifLensModel: "Fixture 50mm",
    ],
    // Present specifically so "Copyright and credit only" has something it
    // is required to throw away.
    kCGImagePropertyGPSDictionary: [
        kCGImagePropertyGPSLatitude: 51.5074,
        kCGImagePropertyGPSLatitudeRef: "N",
        kCGImagePropertyGPSLongitude: 0.1278,
        kCGImagePropertyGPSLongitudeRef: "W",
    ],
]

let image = marker(width: 200, height: 100)
let outputs: [(String, String)] = [
    ("rotated.jpg", UTType.jpeg.identifier),
    ("rotated.heic", UTType.heic.identifier),
    ("rotated.png", UTType.png.identifier),
]

for (name, type) in outputs {
    let url = outputDirectory.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, type as CFString, 1, nil
    ) else { fatalError("could not create a destination for \(name)") }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("could not write \(name)")
    }
    print("wrote \(url.path)")
}
