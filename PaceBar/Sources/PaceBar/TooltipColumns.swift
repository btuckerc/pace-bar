import AppKit

/// Aligned columns for a native tooltip, which has no layout of its own: it draws plain text in the tooltip font
/// with the default tab stops. Each cell gets as many tabs as it takes to reach its column's shared stop, so a
/// short name such as "Opus" lines up with a longer one.
enum TooltipColumns {
    /// Smallest space left between the widest cell of a column and the next column.
    static let gap: CGFloat = 8

    static func lines(_ rows: [[String]]) -> [String] {
        let font = NSFont.toolTipsFont(ofSize: 0)
        let stops = NSParagraphStyle.default.tabStops.map(\.location)
        let columns = rows.map(\.count).max() ?? 0
        var lines = rows.map { _ in "" }
        var start: CGFloat = 0
        for column in 0..<columns {
            let cells = rows.map { column < $0.count ? $0[column] : "" }
            guard column < columns - 1 else {
                for index in lines.indices {
                    lines[index] += cells[index]
                }
                break
            }
            let ends = cells.map { start + ($0 as NSString).size(withAttributes: [.font: font]).width }
            let widest = (ends.max() ?? start) + self.gap
            // Past the last default stop a tab no longer aligns, so later columns are only spaced apart.
            guard let target = stops.first(where: { $0 >= widest }) else {
                for index in lines.indices {
                    lines[index] += cells[index] + "  "
                }
                start = widest
                continue
            }
            for index in lines.indices {
                let tabs = stops.count(where: { $0 > ends[index] && $0 <= target })
                lines[index] += cells[index] + String(repeating: "\t", count: tabs)
            }
            start = target
        }
        return lines
    }
}
