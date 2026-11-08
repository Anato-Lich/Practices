#!/usr/bin/env swift
// Draws the Practices app icon with Core Graphics and writes every size macOS asks for.
//
//     swift tools/make-icon.swift PracticesApp/Sources/Practices/Assets.xcassets/AppIcon.appiconset
//
// The mark: the family's dark rounded plate (Tandem, Selects) and on it three book spines in
// the family's amber — the catalogue (the menu-bar glyph MenuBarIcon is the same figure):
// two upright, the third leaning on them. Everything is drawn here; no third-party artwork.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".", isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let space = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

let plateTop = rgb(0.157, 0.157, 0.168)
let plateBottom = rgb(0.086, 0.086, 0.094)
let amber = rgb(0.925, 0.760, 0.435)
let amberDeep = rgb(0.835, 0.620, 0.290)
let shelf = rgb(0.255, 0.255, 0.271)

/// A book: a rounded spine filled with the warm gradient, a darker band near the top (the label).
func book(_ ctx: CGContext, _ rect: CGRect, tilt: Double, radius: Double) {
    ctx.saveGState()
    // Tilt about the bottom edge so the leaning book still stands on the shelf.
    ctx.translateBy(x: rect.midX, y: rect.minY)
    ctx.rotate(by: tilt)
    ctx.translateBy(x: -rect.midX, y: -rect.minY)
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.clip()
    let warm = CGGradient(colorsSpace: space, colors: [amber, amberDeep] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(warm, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    let band = CGRect(x: rect.minX, y: rect.maxY - rect.height * 0.30, width: rect.width, height: rect.height * 0.085)
    ctx.setFillColor(rgb(0, 0, 0, 0.28))
    ctx.fill(band)
    ctx.fill(band.offsetBy(dx: 0, dy: -rect.height * 0.14))
    ctx.restoreGState()
}

func drawIcon(size: Int) -> CGImage {
    let s = Double(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let inset = s * 0.094
    let plate = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = plate.width * 0.223
    let platePath = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [plateTop, plateBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: plate.maxY), end: CGPoint(x: 0, y: plate.minY), options: [])

    // Shelf line the books stand on.
    let w = plate.width
    let shelfY = plate.minY + w * 0.26
    ctx.setFillColor(shelf)
    ctx.fill(CGRect(x: plate.minX + w * 0.16, y: shelfY - w * 0.012, width: w * 0.68, height: w * 0.024))

    // Two upright books and one leaning on them.
    let bookW = w * 0.13, gap = w * 0.035, corner = w * 0.022
    let x0 = plate.minX + w * 0.26
    book(ctx, CGRect(x: x0, y: shelfY, width: bookW, height: w * 0.50), tilt: 0, radius: corner)
    book(ctx, CGRect(x: x0 + bookW + gap, y: shelfY, width: bookW, height: w * 0.44), tilt: 0, radius: corner)
    book(ctx, CGRect(x: x0 + (bookW + gap) * 2 + w * 0.06, y: shelfY, width: bookW, height: w * 0.48), tilt: -0.26, radius: corner)
    ctx.restoreGState()

    // Hairline highlight on the plate edge, as in the sibling icons.
    ctx.addPath(CGPath(roundedRect: plate.insetBy(dx: s * 0.004, dy: s * 0.004), cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setStrokeColor(rgb(1, 1, 1, 0.07))
    ctx.setLineWidth(s * 0.006)
    ctx.strokePath()

    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

/// Menu-bar template glyph: the same three spines and shelf, solid black on transparent
/// (macOS tints a template image). Drawn on a whole-pixel grid so strokes stay crisp.
func drawGlyph(scale k: Int) -> CGImage {
    let size = 18 * k
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.setFillColor(rgb(0, 0, 0))
    let u = Double(k)                       // one point in pixels
    let shelfY = 3.0 * u, bookW = 3.0 * u, gap = 1.5 * u
    let x0 = 1.0 * u
    // Shelf line, 1 pt thick, full width minus 1 pt padding.
    ctx.fill(CGRect(x: 1 * u, y: 2 * u, width: 16 * u, height: 1 * u))
    func spine(_ x: Double, _ h: Double, tilt: Double) {
        ctx.saveGState()
        ctx.translateBy(x: x + bookW / 2, y: shelfY); ctx.rotate(by: tilt); ctx.translateBy(x: -(x + bookW / 2), y: -shelfY)
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: shelfY, width: bookW, height: h), cornerWidth: 0.5 * u, cornerHeight: 0.5 * u, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()
    }
    spine(x0, 13 * u, tilt: 0)
    spine(x0 + bookW + gap, 11.5 * u, tilt: 0)
    spine(x0 + (bookW + gap) * 2 + 0.5 * u, 12.5 * u, tilt: -0.26)
    return ctx.makeImage()!
}

let glyphDir = outDir.deletingLastPathComponent().appendingPathComponent("MenuBarIcon.imageset", isDirectory: true)
try? FileManager.default.createDirectory(at: glyphDir, withIntermediateDirectories: true)
write(drawGlyph(scale: 1), to: glyphDir.appendingPathComponent("menubar.png"))
write(drawGlyph(scale: 2), to: glyphDir.appendingPathComponent("menubar@2x.png"))
let glyphContents: [String: Any] = [
    "images": [
        ["idiom": "universal", "scale": "1x", "filename": "menubar.png"],
        ["idiom": "universal", "scale": "2x", "filename": "menubar@2x.png"],
    ],
    "info": ["author": "xcode", "version": 1],
    "properties": ["template-rendering-intent": "template", "preserves-vector-representation": false],
]
try! JSONSerialization.data(withJSONObject: glyphContents, options: [.prettyPrinted, .sortedKeys])
    .write(to: glyphDir.appendingPathComponent("Contents.json"))

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    write(drawIcon(size: px), to: outDir.appendingPathComponent("\(name).png"))
}
let contents: [String: Any] = [
    "images": [
        ["idiom": "mac", "scale": "1x", "size": "16x16", "filename": "icon_16x16.png"],
        ["idiom": "mac", "scale": "2x", "size": "16x16", "filename": "icon_16x16@2x.png"],
        ["idiom": "mac", "scale": "1x", "size": "32x32", "filename": "icon_32x32.png"],
        ["idiom": "mac", "scale": "2x", "size": "32x32", "filename": "icon_32x32@2x.png"],
        ["idiom": "mac", "scale": "1x", "size": "128x128", "filename": "icon_128x128.png"],
        ["idiom": "mac", "scale": "2x", "size": "128x128", "filename": "icon_128x128@2x.png"],
        ["idiom": "mac", "scale": "1x", "size": "256x256", "filename": "icon_256x256.png"],
        ["idiom": "mac", "scale": "2x", "size": "256x256", "filename": "icon_256x256@2x.png"],
        ["idiom": "mac", "scale": "1x", "size": "512x512", "filename": "icon_512x512.png"],
        ["idiom": "mac", "scale": "2x", "size": "512x512", "filename": "icon_512x512@2x.png"],
    ],
    "info": ["author": "xcode", "version": 1],
]
let data = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! data.write(to: outDir.appendingPathComponent("Contents.json"))
print("wrote \(sizes.count) icons to \(outDir.path)")
