import AppKit
import CoreText
import Foundation

// Regenerates Resources/AppIcon.iconset. Run from the repo root: swift Tools/makeicon.swift
// Flat cream rounded square, ink hairline, one large lowercase italic "m" in EB Garamond Italic.

let cream = CGColor(red: 1.0, green: 1.0, blue: 0.9216, alpha: 1)      // #FFFFEB
let ink = CGColor(red: 0.1020, green: 0.1020, blue: 0.1020, alpha: 1)  // #1A1A1A

let fontPath = "Resources/Fonts/EBGaramond-Italic[wght].ttf"
let outputDirectory = "Resources/AppIcon.iconset"

// Fractions of the canvas edge, following the macOS icon grid (824 of 1024 for the body).
let bodyFraction: CGFloat = 824.0 / 1024.0
let radiusFraction: CGFloat = 185.0 / 1024.0
let hairlineFraction: CGFloat = 3.0 / 1024.0
let glyphWidthFraction: CGFloat = 0.56    // width of the "m" outline relative to the canvas

guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: fontPath) as CFURL) as? [CTFontDescriptor],
      let descriptor = descriptors.first else {
    print("could not load \(fontPath)")
    exit(1)
}

func render(pixels: Int) -> Data? {
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let side = CGFloat(pixels)
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    let body = side * bodyFraction
    let rect = CGRect(x: (side - body) / 2, y: (side - body) / 2, width: body, height: body)
    let radius = side * radiusFraction
    let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    context.addPath(shape)
    context.setFillColor(cream)
    context.fillPath()

    let hairline = max(1, side * hairlineFraction)
    context.addPath(CGPath(roundedRect: rect.insetBy(dx: hairline / 2, dy: hairline / 2),
                           cornerWidth: radius - hairline / 2, cornerHeight: radius - hairline / 2, transform: nil))
    context.setStrokeColor(ink)
    context.setLineWidth(hairline)
    context.strokePath()

    // Size the font so the m's own outline, not the em box, has the target width.
    let probe = CTFontCreateWithFontDescriptor(descriptor, 1000, nil)
    var character: UniChar = 0x6D
    var glyph = CGGlyph()
    guard CTFontGetGlyphsForCharacters(probe, &character, &glyph, 1) else { return nil }
    guard let probePath = CTFontCreatePathForGlyph(probe, glyph, nil) else { return nil }
    let probeBox = probePath.boundingBoxOfPath
    let fontSize = 1000 * (side * glyphWidthFraction) / probeBox.width

    let font = CTFontCreateWithFontDescriptor(descriptor, fontSize, nil)
    guard let path = CTFontCreatePathForGlyph(font, glyph, nil) else { return nil }
    let box = path.boundingBoxOfPath

    // Centre the outline's bounding box on the canvas. The italic slant already shifts mass to
    // the right at the top, so box centring reads as centred.
    var move = CGAffineTransform(translationX: side / 2 - box.midX, y: side / 2 - box.midY)
    guard let placed = path.copy(using: &move) else { return nil }
    context.addPath(placed)
    context.setFillColor(ink)
    context.fillPath()

    guard let image = context.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

let outputs: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

let fileManager = FileManager.default
try? fileManager.removeItem(atPath: outputDirectory)
try fileManager.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

for (name, pixels) in outputs {
    guard let png = render(pixels: pixels) else {
        print("failed to render \(pixels) x \(pixels)")
        exit(1)
    }
    try png.write(to: URL(fileURLWithPath: outputDirectory).appendingPathComponent(name))
}
print("wrote \(outputs.count) PNGs to \(outputDirectory)")
