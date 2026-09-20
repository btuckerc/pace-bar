import AppKit

/// A split aperture: four offset strokes around a shared center.
/// Drawn once as a template, with no status-driven redraws or animation.
@MainActor
enum UsageIcon {
    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.labelColor.setStroke()
            for index in 0..<4 {
                let transform = AffineTransform(
                    translationByX: 9, byY: 9)
                var rotation = AffineTransform(rotationByDegrees: CGFloat(index) * 90)
                rotation.append(transform)
                let path = NSBezierPath()
                path.move(to: NSPoint(x: -5.5, y: 0.5))
                path.line(to: NSPoint(x: -5.5, y: 3.5))
                path.curve(
                    to: NSPoint(x: -3.5, y: 5.5),
                    controlPoint1: NSPoint(x: -5.5, y: 4.6),
                    controlPoint2: NSPoint(x: -4.6, y: 5.5))
                path.line(to: NSPoint(x: 1.5, y: 5.5))
                path.transform(using: rotation)
                path.lineWidth = 1.7
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Usage Bar"
        return image
    }
}
