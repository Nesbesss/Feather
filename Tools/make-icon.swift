#!/usr/bin/env swift
import AppKit

// Rebuild the editable SVG master and native macOS icon assets with:
// swift Tools/make-icon.swift
// Coordinates share a 1024 pt canvas, with the origin at the top left.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("Feather/Resources/Assets.xcassets")
let brand = root.appendingPathComponent("Brand")
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

let blade = CGMutablePath()
blade.move(to: CGPoint(x: 324, y: 708))
blade.addCurve(to: CGPoint(x: 378, y: 589), control1: CGPoint(x: 341, y: 662), control2: CGPoint(x: 360, y: 622))
blade.addCurve(to: CGPoint(x: 411, y: 402), control1: CGPoint(x: 337, y: 535), control2: CGPoint(x: 348, y: 462))
blade.addCurve(to: CGPoint(x: 714, y: 271), control1: CGPoint(x: 488, y: 329), control2: CGPoint(x: 610, y: 282))
blade.addCurve(to: CGPoint(x: 623, y: 549), control1: CGPoint(x: 732, y: 375), control2: CGPoint(x: 694, y: 477))
blade.addCurve(to: CGPoint(x: 565, y: 581), control1: CGPoint(x: 606, y: 566), control2: CGPoint(x: 586, y: 576))
blade.addLine(to: CGPoint(x: 600, y: 525))
blade.addCurve(to: CGPoint(x: 516, y: 611), control1: CGPoint(x: 573, y: 550), control2: CGPoint(x: 547, y: 590))
blade.addLine(to: CGPoint(x: 472, y: 628))
blade.addLine(to: CGPoint(x: 506, y: 574))
blade.addCurve(to: CGPoint(x: 353, y: 723), control1: CGPoint(x: 442, y: 622), control2: CGPoint(x: 389, y: 664))
blade.addCurve(to: CGPoint(x: 324, y: 708), control1: CGPoint(x: 341, y: 742), control2: CGPoint(x: 316, y: 731))
blade.closeSubpath()

let quill = CGMutablePath()
quill.move(to: CGPoint(x: 341, y: 716))
quill.addCurve(to: CGPoint(x: 650, y: 341), control1: CGPoint(x: 420, y: 574), control2: CGPoint(x: 526, y: 444))

func gradient(_ context: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func draw(_ context: CGContext, tile: Bool) {
    if tile {
        let tilePath = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                              cornerWidth: 185, cornerHeight: 185, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 13), blur: 24, color: color(0.09, 0.21, 0.31, 0.19))
        context.addPath(tilePath)
        context.setFillColor(color(0.66, 0.81, 0.88))
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(tilePath)
        context.clip()
        gradient(context, [color(0.90, 0.96, 0.98), color(0.59, 0.77, 0.86), color(0.30, 0.53, 0.66)],
                 from: CGPoint(x: 175, y: 110), to: CGPoint(x: 806, y: 924))
        context.restoreGState()
        context.addPath(tilePath)
        context.setStrokeColor(color(1, 1, 1, 0.65))
        context.setLineWidth(2)
        context.strokePath()
    }
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 14), blur: 22, color: color(0.11, 0.31, 0.43, tile ? 0.23 : 0.13))
    context.addPath(blade)
    context.setFillColor(color(0.77, 0.90, 0.96))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(blade)
    context.clip()
    gradient(context, [color(1, 1, 1, 0.98), color(0.91, 0.97, 1, 0.94), color(0.49, 0.73, 0.86, 0.92)],
             from: CGPoint(x: 400, y: 340), to: CGPoint(x: 625, y: 737))
    context.restoreGState()
    context.addPath(blade)
    context.setStrokeColor(color(1, 1, 1, 0.82))
    context.setLineWidth(3)
    context.setLineJoin(.round)
    context.strokePath()
    context.saveGState()
    context.addPath(blade)
    context.clip()
    context.addPath(quill)
    context.setLineWidth(9)
    context.setLineCap(.round)
    context.setStrokeColor(color(0.27, 0.53, 0.69, 0.50))
    context.strokePath()
    context.translateBy(x: -3, y: -2)
    context.addPath(quill)
    context.setLineWidth(3)
    context.setStrokeColor(color(1, 1, 1, 0.85))
    context.strokePath()
    context.restoreGState()
}

func png(size: Int, tile: Bool) -> Data {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: CGFloat(size) / 1024, y: -CGFloat(size) / 1024)
    if !tile {
        // Crop the mark to a 600 pt square for clear in-app display.
        context.translateBy(x: -375, y: -335)
        context.scaleBy(x: 1.75, y: 1.75)
    }
    draw(context, tile: tile)
    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: brand, withIntermediateDirectories: true)
try Data("{\"info\":{\"author\":\"xcode\",\"version\":1}}\n".utf8).write(to: assets.appendingPathComponent("Contents.json"))
var icons: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        let directory = assets.appendingPathComponent("AppIcon.appiconset")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png(size: size * scale, tile: true).write(to: directory.appendingPathComponent(filename))
        icons.append(["filename": filename, "idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x"])
    }
}
var marks: [[String: String]] = []
for scale in [1, 2, 3] {
    let filename = "feather\(scale == 1 ? "" : "@\(scale)x").png"
    let directory = assets.appendingPathComponent("FeatherMark.imageset")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try png(size: 128 * scale, tile: false).write(to: directory.appendingPathComponent(filename))
    marks.append(["filename": filename, "idiom": "universal", "scale": "\(scale)x"])
}
for (name, images) in [("AppIcon.appiconset", icons), ("FeatherMark.imageset", marks)] {
    let data = try JSONSerialization.data(withJSONObject: ["images": images, "info": ["author": "xcode", "version": 1]],
                                         options: [.prettyPrinted, .sortedKeys])
    try data.write(to: assets.appendingPathComponent(name).appendingPathComponent("Contents.json"))
}

func svgPath(_ path: CGPath) -> String {
    var result: [String] = []
    func point(_ p: CGPoint) -> String { "\(Int(p.x)),\(Int(p.y))" }
    path.applyWithBlock { element in
        let e = element.pointee
        switch e.type {
        case .moveToPoint: result.append("M" + point(e.points[0]))
        case .addLineToPoint: result.append("L" + point(e.points[0]))
        case .addCurveToPoint: result.append("C" + (0..<3).map { point(e.points[$0]) }.joined(separator: " "))
        case .closeSubpath: result.append("Z")
        case .addQuadCurveToPoint: break
        @unknown default: break
        }
    }
    return result.joined(separator: " ")
}
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="200 200 600 600" fill="none">
  <title>Feather</title>
  <defs>
    <linearGradient id="glass" x1="400" y1="340" x2="625" y2="737" gradientUnits="userSpaceOnUse">
      <stop stop-color="#fff"/><stop offset=".5" stop-color="#e8f7ff"/><stop offset="1" stop-color="#7dbadb"/>
    </linearGradient>
    <filter id="shadow" x="-30%" y="-30%" width="160%" height="160%"><feDropShadow dx="0" dy="14" stdDeviation="11" flood-color="#1c4f6e" flood-opacity=".13"/></filter>
    <clipPath id="blade"><path d="\(svgPath(blade))"/></clipPath>
  </defs>
  <path d="\(svgPath(blade))" fill="url(#glass)" stroke="#fff" stroke-opacity=".82" stroke-width="3" stroke-linejoin="round" filter="url(#shadow)"/>
  <g clip-path="url(#blade)" stroke-linecap="round">
    <path d="\(svgPath(quill))" stroke="#4587b0" stroke-opacity=".5" stroke-width="9"/>
    <path d="\(svgPath(quill))" transform="translate(-3 -2)" stroke="#fff" stroke-opacity=".85" stroke-width="3"/>
  </g>
</svg>

"""
try Data(svg.utf8).write(to: brand.appendingPathComponent("Feather.svg"))
try png(size: 1024, tile: true).write(to: brand.appendingPathComponent("Feather-AppIcon.png"))
try png(size: 1024, tile: false).write(to: brand.appendingPathComponent("Feather-Mark.png"))
print("Rebuilt Feather logo, mark and macOS app icon.")
