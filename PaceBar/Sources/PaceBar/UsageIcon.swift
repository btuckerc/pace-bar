import AppKit
import PaceBarCore

/// The status-item glyph. Template tinting follows the menu bar's appearance.
/// Values are quantized by QuotaIconState; no animation or independent refresh work.
@MainActor
enum UsageIcon {
    static func image(_ state: QuotaIconState, style: MenuBarIcon) -> NSImage {
        let image = switch style {
        case .bars: self.bars(state)
        case .orbit: self.orbit(state.levels)
        }
        image.isTemplate = true
        image.accessibilityDescription = "Pace Bar"
        return image
    }

    /// Codex 1–4 as upright level bars, then Claude 1 after a wider gap. Twelve steps are one point each.
    private static func bars(_ state: QuotaIconState) -> NSImage {
        NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            let width = CGFloat(2.3)
            let height = CGFloat(12)
            let bottom = CGFloat(3)
            let slots = zip([2.5, 6, 9.5, 13, 18.5] as [CGFloat], state.levels + [state.claude])
            for (center, level) in slots {
                guard let level else {
                    // Broken tracks indicate unavailable data, never an invented balance.
                    NSColor.black.withAlphaComponent(0.6).setFill()
                    for y in [4.5, 9, 13.5] as [CGFloat] {
                        NSBezierPath(ovalIn: NSRect(x: center - 0.55, y: y - 0.55, width: 1.1, height: 1.1)).fill()
                    }
                    continue
                }
                let track = NSRect(x: center - width / 2, y: bottom, width: width, height: height)
                NSColor.black.withAlphaComponent(0.3).setFill()
                NSBezierPath(roundedRect: track, xRadius: width / 2, yRadius: width / 2).fill()
                let clamped = min(12, max(0, level))
                guard clamped > 0 else { continue }
                // Never shorter than its own rounded cap, so one step stays visible.
                let fill = NSRect(
                    x: track.minX, y: bottom, width: width, height: max(width, height * CGFloat(clamped) / 12))
                NSColor.black.setFill()
                NSBezierPath(roundedRect: fill, xRadius: width / 2, yRadius: width / 2).fill()
            }
            return true
        }
    }

    /// Four separated Codex arcs around an empty center, matching the app icon.
    private static func orbit(_ levels: [Int?]) -> NSImage {
        NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
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
