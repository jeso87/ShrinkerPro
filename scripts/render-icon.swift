import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Takes the full-bleed square Icon Composer renders and re-lays it out to
// macOS's app-icon geometry, then writes every size the asset catalog needs.
//
// Why any padding at all: `ictool` renders a .icon edge to edge, because
// macOS 26 masks and insets app icons itself. Everything before macOS 26 —
// including this app's deployment target of 14.0 — draws the .icns exactly
// as given, so a full-bleed icon renders visibly larger than every
// neighbouring app in the Dock.
//
// The numbers are measured, not guessed: Mail, Notes and Safari all place
// 856x856 of artwork in a 1024x1024 canvas, with margins of 84 left/right,
// 92 top and 76 bottom — i.e. centred horizontally and nudged 8pt down to
// leave room for the shadow. Those ratios are reproduced here at every size.

let apple = (artwork: 856.0, margin: 84.0, top: 92.0, canvas: 1024.0)

guard CommandLine.arguments.count == 4 else {
    FileHandle.standardError.write("usage: render-icon.swift <source.png> <out-dir> <sizes,comma,separated>\n".data(using: .utf8)!)
    exit(2)
}
let sourcePath = CommandLine.arguments[1]
let outDir = URL(fileURLWithPath: CommandLine.arguments[2])
let sizes = CommandLine.arguments[3].split(separator: ",").compactMap { Int($0) }

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: sourcePath) as CFURL, nil),
      let source = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write("cannot read \(sourcePath)\n".data(using: .utf8)!)
    exit(1)
}
guard source.width == source.height else {
    FileHandle.standardError.write("source must be square, got \(source.width)x\(source.height)\n".data(using: .utf8)!)
    exit(1)
}

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

for size in sizes {
    let n = Double(size)
    let artwork = (n * apple.artwork / apple.canvas).rounded()
    let left = ((n - artwork) / 2).rounded()
    let top = (n * apple.top / apple.canvas).rounded()

    guard let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        FileHandle.standardError.write("cannot create \(size)px context\n".data(using: .utf8)!)
        exit(1)
    }
    ctx.interpolationQuality = .high
    // CoreGraphics' origin is bottom-left; `top` is measured from the top,
    // so the y origin is what is left underneath the artwork.
    let y = n - top - artwork
    ctx.draw(source, in: CGRect(x: left, y: y, width: artwork, height: artwork))

    guard let out = ctx.makeImage() else {
        FileHandle.standardError.write("render failed at \(size)px\n".data(using: .utf8)!)
        exit(1)
    }
    let dest = outDir.appendingPathComponent("icon_\(size).png")
    guard let writer = CGImageDestinationCreateWithURL(dest as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write("cannot write \(dest.path)\n".data(using: .utf8)!)
        exit(1)
    }
    CGImageDestinationAddImage(writer, out, nil)
    guard CGImageDestinationFinalize(writer) else {
        FileHandle.standardError.write("finalize failed for \(dest.path)\n".data(using: .utf8)!)
        exit(1)
    }
}

print("rendered \(sizes.count) sizes into \(outDir.path)")
