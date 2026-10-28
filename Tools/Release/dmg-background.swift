import AppKit

// Code-drawn artwork keeps the install screen editable and reproducible.
let args = CommandLine.arguments
guard args.count == 4 else { fatalError("usage: swift dmg-background.swift OUTPUT.png BRAND.png preview|release") }
let size = NSSize(width: 760, height: 500)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1520, pixelsHigh: 1000,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let context = NSGraphicsContext.current!.cgContext
context.translateBy(x: 0, y: 500)
context.scaleBy(x: 1, y: -1)
let background = NSGradient(colors: [NSColor(calibratedRed: 0.96, green: 0.98, blue: 1, alpha: 1),
    NSColor(calibratedRed: 0.86, green: 0.92, blue: 0.96, alpha: 1)])!
background.draw(in: NSRect(origin: .zero, size: size), angle: 90)
func label(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat,
           _ font: NSFont, _ color: NSColor, centered: Bool = false) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = centered ? .center : .left
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    // Text requires its own upright coordinate space inside the flipped canvas.
    context.saveGState()
    context.translateBy(x: 0, y: 500)
    context.scaleBy(x: 1, y: -1)
    (text as NSString).draw(in: NSRect(x: x, y: 500 - y - 52, width: width, height: 52), withAttributes: attrs)
    context.restoreGState()
}
let ink = NSColor(calibratedRed: 0.12, green: 0.22, blue: 0.3, alpha: 1)
let muted = NSColor(calibratedRed: 0.37, green: 0.47, blue: 0.54, alpha: 1)
label("F E A T H E R", 0, 42, 760, .systemFont(ofSize: 12, weight: .semibold), muted, centered: true)
label("Make yourself at home.", 0, 78, 760, .systemFont(ofSize: 32, weight: .medium), ink, centered: true)
label("Drag Feather to Applications to get started.", 0, 124, 760, .systemFont(ofSize: 15), muted, centered: true)
for x: CGFloat in [190, 570] {
    NSColor.white.withAlphaComponent(0.44).setFill()
    NSBezierPath(roundedRect: NSRect(x: x - 87, y: 192, width: 174, height: 174), xRadius: 34, yRadius: 34).fill()
}
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 344, y: 267)); arrow.line(to: NSPoint(x: 414, y: 267))
arrow.move(to: NSPoint(x: 403, y: 256)); arrow.line(to: NSPoint(x: 414, y: 267)); arrow.line(to: NSPoint(x: 403, y: 278))
arrow.lineWidth = 2.5; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
muted.withAlphaComponent(0.7).setStroke(); arrow.stroke()
NSColor.white.withAlphaComponent(0.6).setFill()
NSBezierPath(rect: NSRect(x: 64, y: 408, width: 632, height: 1)).fill()
label("Native to Mac. Built on WebKit.", 64, 430, 400, .systemFont(ofSize: 12), muted)
label(args[3] == "preview" ? "LOCAL PREVIEW · NOT NOTARIZED" : "macOS 26 or later", 385, 430, 310,
      .systemFont(ofSize: 10, weight: .medium), muted, centered: true)
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))
