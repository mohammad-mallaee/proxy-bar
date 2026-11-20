// Draws ProxyBar's app icon and writes an .iconset folder.
// Usage: swift scripts/make-icon.swift Resources/AppIcon.iconset
//        iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(pixels px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(px) / 1024
    // macOS icon grid: 824×824 rounded square centered on a 1024 canvas.
    let rect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tile = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 24 * s
    shadow.set()
    NSColor.black.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    NSGradient(colors: [
        color(0.04, 0.12, 0.23),
        color(0.08, 0.30, 0.39),
    ])!.draw(in: tile, angle: 65)
    color(0.57, 0.88, 0.98, alpha: 0.28).setStroke()
    tile.lineWidth = 4 * s
    tile.stroke()

    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: x * s, y: y * s)
    }

    func node(at center: NSPoint, radius: CGFloat, fill: NSColor) {
        let r = radius * s
        fill.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)).fill()
    }

    let input = point(295, 408)
    let outgoing = point(729, 656)
    let bypass = point(729, 408)
    let mint = color(0.57, 1, 0.81)
    let muted = color(0.33, 0.58, 0.65)

    // The shorter branch stays visible behind the highlighted proxy route.
    let direct = NSBezierPath()
    direct.move(to: input)
    direct.line(to: bypass)
    direct.lineWidth = 34 * s
    muted.setStroke()
    direct.stroke()
    node(at: bypass, radius: 37, fill: muted)

    let route = NSBezierPath()
    route.move(to: input)
    route.line(to: point(397, 408))
    route.curve(to: point(512, 523), controlPoint1: point(461, 408), controlPoint2: point(512, 459))
    route.line(to: point(512, 541))
    route.curve(to: point(627, 656), controlPoint1: point(512, 605), controlPoint2: point(563, 656))
    route.line(to: outgoing)
    route.lineCapStyle = .round
    route.lineWidth = 58 * s
    mint.setStroke()
    route.stroke()
    node(at: input, radius: 53, fill: mint)
    node(at: outgoing, radius: 60, fill: mint)
    node(at: outgoing, radius: 24, fill: color(0.07, 0.27, 0.36))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(pixels: base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(pixels: base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("Wrote \(out.path)")
