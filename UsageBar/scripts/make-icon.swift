import AppKit

// The menu-bar mark is four 65-degree arcs, separated by 25-degree gaps.
// The application icon uses the same geometry, without representing live quota.
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

        let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
                                xRadius: 185, yRadius: 185)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
        shadow.shadowBlurRadius = 26
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.set()
        NSColor(calibratedRed: 0.055, green: 0.15, blue: 0.19, alpha: 1).setFill()
        tile.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGradient(
            starting: NSColor(calibratedRed: 0.10, green: 0.30, blue: 0.34, alpha: 1),
            ending: NSColor(calibratedRed: 0.035, green: 0.10, blue: 0.16, alpha: 1))!
            .draw(in: tile, angle: -65)
        NSColor.white.withAlphaComponent(0.12).setStroke()
        tile.lineWidth = 2
        tile.stroke()

        NSColor(calibratedRed: 0.84, green: 0.98, blue: 0.94, alpha: 1).setStroke()
        for start: CGFloat in [122.5, 32.5, -57.5, 212.5] {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: 512, y: 512), radius: 245,
                          startAngle: start, endAngle: start - 65, clockwise: true)
            arc.lineWidth = 84
            arc.lineCapStyle = .round
            arc.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
