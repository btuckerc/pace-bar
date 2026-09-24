import AppKit

/// Four separated quota arcs around an empty center. Template tinting follows the menu bar's appearance.
/// Values are quantized by QuotaIconState; no animation or independent refresh work.
@MainActor
enum UsageIcon {
    static func image(levels: [Int?] = [nil, nil, nil, nil]) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let center = NSPoint(x: 9, y: 9)
            let radius = CGFloat(6)
            let strokeWidth = CGFloat(2.1)
            let segmentSpan = CGFloat(65)
            let starts: [CGFloat] = [122.5, 32.5, -57.5, 212.5] // Codex 1-4, clockwise from top

            for index in 0..<4 {
                let start = starts[index]
                let end = start - segmentSpan
                guard index < levels.count, let level = levels[index] else {
                    // Broken tracks indicate unavailable data, never an invented balance.
                    NSColor.black.withAlphaComponent(0.6).setFill()
                    for offset in [10.0, 32.5, 55.0] {
                        let radians = (start - offset) * .pi / 180
                        NSBezierPath(
                            ovalIn: NSRect(
                                x: center.x + cos(radians) * radius - 0.55,
                                y: center.y + sin(radians) * radius - 0.55,
                                width: 1.1,
                                height: 1.1)).fill()
                    }
                    continue
                }

                // A quiet full track keeps the four slots legible at every balance.
                NSColor.black.withAlphaComponent(0.32).setStroke()
                Self.arc(
                    center: center,
                    radius: radius,
                    startAngle: start,
                    endAngle: end,
                    lineWidth: strokeWidth)

                let clampedLevel = min(12, max(0, level))
                if clampedLevel > 0 {
                    NSColor.black.setStroke()
                    Self.arc(
                        center: center,
                        radius: radius,
                        startAngle: start,
                        endAngle: start - segmentSpan * CGFloat(clampedLevel) / 12,
                        lineWidth: strokeWidth)
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Usage Bar"
        return image
    }

    private static func arc(
        center: NSPoint,
        radius: CGFloat,
        startAngle: CGFloat,
        endAngle: CGFloat,
        lineWidth: CGFloat)
    {
        let path = NSBezierPath()
        path.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: true)
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.stroke()
    }
}
