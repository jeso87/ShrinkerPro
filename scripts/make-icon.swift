#!/usr/bin/env swift
import AppKit
import CoreGraphics

// Emits square PNGs of the Shrinker Pro icon at every size macOS asks for.

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let outputDir = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: "icon-out")
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

func draw(size: Int) -> Data? {
    let s = CGFloat(size)
    guard let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // Rounded-square mask, matching macOS icon proportions.
    let inset = s * 0.055
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let corner = rect.width * 0.2237
    let squircle = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    context.addPath(squircle)
    context.clip()

    // Indigo -> violet gradient.
    let colors = [
        CGColor(red: 0.298, green: 0.259, blue: 0.749, alpha: 1),
        CGColor(red: 0.529, green: 0.259, blue: 0.831, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 colors: colors, locations: [0, 1]) {
        context.drawLinearGradient(
            gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: []
        )
    }

    // Top inner highlight: fades from a soft glow at the very top of the
    // icon down to nothing, rather than a flat-alpha fill. A flat fill over
    // a hard-edged rect reads as lighting only up close — at 512/128/256px
    // it shows a crisp, ruler-straight edge where the fill rect ends and
    // the gradient resumes, which looks like a printing defect, not light.
    // Fading the alpha to 0 at the band's lower edge removes that edge
    // entirely while keeping the "lit from above" cue legible.
    let highlightBand = CGRect(x: rect.minX, y: rect.maxY - rect.height * 0.09,
                               width: rect.width, height: rect.height * 0.09)
    context.saveGState()
    context.clip(to: highlightBand)
    let highlightColors = [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.16),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0),
    ] as CFArray
    if let highlightGradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          colors: highlightColors, locations: [0, 1]) {
        context.drawLinearGradient(
            highlightGradient,
            start: CGPoint(x: 0, y: highlightBand.maxY), end: CGPoint(x: 0, y: highlightBand.minY),
            options: []
        )
    }
    context.restoreGState()

    // Central "image" plate.
    let plateW = rect.width * 0.34, plateH = rect.height * 0.44
    let plate = CGRect(x: rect.midX - plateW / 2, y: rect.midY - plateH / 2,
                       width: plateW, height: plateH)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    context.addPath(CGPath(roundedRect: plate, cornerWidth: plateW * 0.14,
                           cornerHeight: plateW * 0.14, transform: nil))
    context.fillPath()

    // Inward chevrons: compression.
    // At small sizes (16px) a short arm with a comparable-or-larger line
    // width collapses the chevron into a blurry dot rather than a legible
    // "<"/">" shape. Keeping the arm meaningfully longer than the stroke
    // (and both sized off rect.width, not raw pixel count) keeps the
    // chevrons distinct at 16px while still reading cleanly at 1024px —
    // tuned by rendering at 16px and inspecting the PNG directly.
    let lw = max(1.3, rect.width * 0.05)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    context.setLineWidth(lw)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    let gap = rect.width * 0.07, arm = rect.width * 0.20
    for direction in [-1.0, 1.0] {
        let tipX = plate.midX + CGFloat(direction) * (plateW / 2 + gap)
        context.move(to: CGPoint(x: tipX + CGFloat(direction) * arm, y: rect.midY + arm))
        context.addLine(to: CGPoint(x: tipX, y: rect.midY))
        context.addLine(to: CGPoint(x: tipX + CGFloat(direction) * arm, y: rect.midY - arm))
    }
    context.strokePath()

    guard let image = context.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])
}

for size in sizes {
    guard let data = draw(size: size) else { fatalError("failed to render \(size)") }
    try data.write(to: outputDir.appendingPathComponent("icon_\(size).png"))
    print("rendered \(size)x\(size)")
}
