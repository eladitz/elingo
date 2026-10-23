// Draws the app icon: two pages side by side, one in another language ("Ä") and its mirror ("A"),
// with a signature stroke, on a dark teal tile.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func page(_ rect: NSRect, angle: CGFloat, letter: String, ink: NSColor, s: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: rect.midX, yBy: rect.midY)
    t.rotate(byDegrees: angle)
    t.translateX(by: -rect.midX, yBy: -rect.midY)
    t.concat()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.008)
    shadow.set()
    color(0xF7F8FA).setFill()
    NSBezierPath(roundedRect: rect, xRadius: s * 0.025, yRadius: s * 0.025).fill()
    NSShadow().set()
    let font = NSFont.systemFont(ofSize: rect.width * 0.62, weight: .bold)
    let text = NSAttributedString(string: letter, attributes: [.font: font, .foregroundColor: ink])
    let size = text.size()
    text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.maxY - size.height - rect.height * 0.08))
    color(0xC9CED6).setFill()
    for i in 0..<2 {
        NSBezierPath(roundedRect: NSRect(x: rect.minX + rect.width * 0.16, y: rect.minY + rect.height * (0.3 - CGFloat(i) * 0.1),
                                         width: rect.width * (i == 0 ? 0.68 : 0.5), height: s * 0.014), xRadius: s * 0.007, yRadius: s * 0.007).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
}

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)

    let tile = NSBezierPath(roundedRect: NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8), xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(colors: [color(0x1F6F78), color(0x123A4A)])!.draw(in: tile, angle: -90)

    page(NSRect(x: s * 0.2, y: s * 0.27, width: s * 0.3, height: s * 0.42), angle: 6, letter: "Ä", ink: color(0x8A93A3), s: s)
    page(NSRect(x: s * 0.47, y: s * 0.29, width: s * 0.3, height: s * 0.42), angle: -5, letter: "A", ink: color(0x2F7FE0), s: s)

    // The signature, running across both pages.
    let pen = NSBezierPath()
    pen.lineWidth = s * 0.022
    pen.lineCapStyle = .round
    pen.move(to: NSPoint(x: s * 0.26, y: s * 0.24))
    pen.curve(to: NSPoint(x: s * 0.44, y: s * 0.27), controlPoint1: NSPoint(x: s * 0.32, y: s * 0.36), controlPoint2: NSPoint(x: s * 0.36, y: s * 0.14))
    pen.curve(to: NSPoint(x: s * 0.62, y: s * 0.25), controlPoint1: NSPoint(x: s * 0.5, y: s * 0.38), controlPoint2: NSPoint(x: s * 0.55, y: s * 0.15))
    pen.curve(to: NSPoint(x: s * 0.76, y: s * 0.27), controlPoint1: NSPoint(x: s * 0.67, y: s * 0.32), controlPoint2: NSPoint(x: s * 0.71, y: s * 0.22))
    color(0xFFB13B).setStroke()
    pen.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! draw(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
