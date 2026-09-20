import AppKit

/// Four open reservoirs. Template tinting follows the menu bar's appearance.
/// Values are quantized by QuotaIconState; no animation or independent refresh work.
@MainActor
enum UsageIcon {
    static func image(levels: [Int?] = [nil, nil, nil, nil]) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            for index in 0..<4 {
                let x = CGFloat(2 + index * 4)
                guard index < levels.count, let level = levels[index] else {
                    // Broken tracks indicate unavailable data, never an invented balance.
                    NSColor.black.withAlphaComponent(0.6).setFill()
                    for y in [3.0, 8.5, 14.0] {
                        Self.capsule(x: x, y: y, width: 2, height: 1)
                    }
                    continue
                }
                NSColor.black.withAlphaComponent(0.18).setFill()
                Self.capsule(x: x, y: 2.5, width: 2, height: 13)
                NSColor.black.setFill()
                // An exhausted account retains a thin baseline; every positive value is taller.
                Self.capsule(x: x, y: 2.5, width: 2, height: 1 + CGFloat(min(12, max(0, level))))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Usage Bar"
        return image
    }

    private static func capsule(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        NSBezierPath(
            roundedRect: NSRect(x: x, y: y, width: width, height: height),
            xRadius: min(width, height) / 2,
            yRadius: min(width, height) / 2).fill()
    }
}
