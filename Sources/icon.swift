import AppKit

func appIcon(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(size) / 1_024)
    transform.concat()

    let base = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
                            xRadius: 204, yRadius: 204)
    NSGradient(starting: NSColor(srgbRed: 0.05, green: 0.28, blue: 0.72, alpha: 1),
               ending: NSColor(srgbRed: 0.13, green: 0.63, blue: 0.98, alpha: 1))!
        .draw(in: base, angle: 60)

    let brackets = NSBezierPath()
    for (x, y, dx, dy) in [(278.0, 278.0, 1.0, 1.0), (746.0, 278.0, -1.0, 1.0),
                            (278.0, 746.0, 1.0, -1.0), (746.0, 746.0, -1.0, -1.0)] {
        brackets.move(to: NSPoint(x: x, y: y + 92 * dy))
        brackets.line(to: NSPoint(x: x, y: y))
        brackets.line(to: NSPoint(x: x + 92 * dx, y: y))
    }
    brackets.lineWidth = 42
    brackets.lineCapStyle = .round
    brackets.lineJoinStyle = .round
    NSColor.white.setStroke()
    brackets.stroke()

    NSColor.white.withAlphaComponent(0.98).setFill()
    NSBezierPath(ovalIn: NSRect(x: 434, y: 434, width: 156, height: 156)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for size in [16, 32, 128, 256, 512] {
    try appIcon(size: size).write(to: folder.appendingPathComponent("icon_\(size)x\(size).png"))
    try appIcon(size: size * 2).write(to: folder.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
