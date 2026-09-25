import AppKit
import PaceBarCore

@MainActor
enum UsageIcon {
    static func image(_ state: QuotaIconState, style: MenuBarIcon) -> NSImage {
        let groups = state.groups
        let widths = groups.map { group in
            style == .orbit ? CGFloat(group.summarized ? 30 : 18) :
                CGFloat(group.summarized ? 22 : group.levels.count * 4)
        }
        let width = max(18, widths.reduce(0, +) + CGFloat(max(0, groups.count - 1) * 5))
        let image = NSImage(size: NSSize(width: width, height: 18), flipped: false) { _ in
            var x: CGFloat = 0
            if groups.isEmpty {
                NSColor.black.withAlphaComponent(0.5).setStroke()
                Self.arc(center: NSPoint(x: 9, y: 9), start: 90, end: -269, alpha: 0.5)
            }
            for (index, group) in groups.enumerated() {
                let levels = group.levels
                if style == .bars {
                    for (slot, level) in levels.enumerated() {
                        let rect = NSRect(x: x + CGFloat(slot * 4) + 1, y: 3, width: 2.3, height: 12)
                        if let level {
                            NSColor.black.withAlphaComponent(0.3).setFill()
                            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
                            if level > 0 {
                                NSColor.black.setFill()
                                NSBezierPath(
                                    roundedRect: NSRect(
                                        x: rect.minX,
                                        y: 3,
                                        width: 2.3,
                                        height: max(2.3, CGFloat(level))),
                                    xRadius: 1,
                                    yRadius: 1).fill()
                            }
                        } else {
                            NSColor.black.withAlphaComponent(0.6).setFill()
                            for y in [4.5, 9, 13.5] as [CGFloat] {
                                NSBezierPath(ovalIn: NSRect(x: rect.minX + 0.5, y: y, width: 1.1, height: 1.1)).fill()
                            }
                        }
                    }
                } else {
                    let span = 360 / CGFloat(levels.count)
                    for (slot, level) in levels.enumerated() {
                        let start = 90 - CGFloat(slot) * span - 5
                        let end = start - span + 10
                        let center = NSPoint(x: x + 9, y: 9)
                        if let level {
                            Self.arc(center: center, start: start, end: end, alpha: 0.3)
                            if level > 0 { Self.arc(
                                center: center,
                                start: start,
                                end: start - (span - 10) * CGFloat(level) / 12,
                                alpha: 1) }
                        } else {
                            for part in 0..<3 {
                                let angle = (start - (span - 10) * CGFloat(part + 1) / 4) * .pi / 180
                                NSColor.black.withAlphaComponent(0.6).setFill()
                                NSBezierPath(ovalIn: NSRect(
                                    x: center.x + cos(angle) * 6 - 0.5,
                                    y: center.y + sin(angle) * 6 - 0.5,
                                    width: 1.1,
                                    height: 1.1)).fill()
                            }
                        }
                    }
                }
                if group.summarized {
                    let count = "×\(group.accounts.count)" as NSString
                    count.draw(
                        at: NSPoint(x: x + (style == .orbit ? 17 : 5), y: 4),
                        withAttributes: [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.black])
                }
                x += widths[index] + 5
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = state.accessibilityDescription
        return image
    }

    private static func arc(center: NSPoint, start: CGFloat, end: CGFloat, alpha: CGFloat) {
        NSColor.black.withAlphaComponent(alpha).setStroke()
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: 6, startAngle: start, endAngle: end, clockwise: true)
        path.lineWidth = 2.1
        path.lineCapStyle = .round
        path.stroke()
    }
}
