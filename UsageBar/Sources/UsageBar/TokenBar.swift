import SwiftUI
import UsageBarCore

/// Lifetime tokens as one bar: how much was cache, fresh input, and output.
struct TokenBar: View {
    let totals: NousLifetimeTotals?

    private var parts: [(name: String, value: Double, tint: Color)] {
        [
            ("cache", self.totals?.cachedTokens ?? 0, Palette.localSoft),
            ("in", self.totals?.promptTokens ?? 0, Palette.local),
            ("out", self.totals?.outputTokens ?? 0, Palette.localDeep),
        ]
    }

    var body: some View {
        let parts = self.parts
        let total = parts.map(\.value).reduce(0, +)
        let prompt = parts[0].value + parts[1].value
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tokens").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(total > 0 ? Self.compact(total) : "—")
                    .font(.system(size: 13, weight: .medium)).monospacedDigit()
                Spacer()
                if prompt > 0 {
                    Text("\(Int((parts[0].value / prompt * 100).rounded()))% cached")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(parts.indices, id: \.self) { index in
                        if parts[index].value > 0 {
                            Capsule().fill(parts[index].tint)
                                .frame(width: max(3, (geometry.size.width - 4) * parts[index].value / total))
                        }
                    }
                }
            }
            .frame(height: 5)
            .opacity(total > 0 ? 1 : 0)
            HStack(spacing: 10) {
                ForEach(parts.indices, id: \.self) { index in
                    HStack(spacing: 4) {
                        Circle().fill(parts[index].tint).frame(width: 6, height: 6)
                        Text("\(parts[index].name) \(self.totals == nil ? "—" : Self.compact(parts[index].value))")
                    }
                }
            }
            .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
        }
        .help("Lifetime tokens on nous across models and restarts")
    }

    private static func compact(_ value: Double) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")).notation(.compactName)
            .precision(.fractionLength(0...1)))
    }
}
