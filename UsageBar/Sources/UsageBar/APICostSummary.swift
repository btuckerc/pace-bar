import SwiftUI
import UsageBarCore

/// Codex and Claude API-equivalent spend, combined per window. The pair reveals together; once revealed, each
/// amount shows a two-tone split and one caption carries the legend and the not-billed caveat.
struct APICostSummary: View {
    let codex: APICostEstimate?
    let claude: APICostEstimate?
    @State private var visible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 12) {
                self.metric("API equivalent · 7d", codex: self.codex?.weekUSD, claude: self.claude?.weekUSD)
                self.metric("API equivalent · 30d", codex: self.codex?.usd, claude: self.claude?.usd)
            }
            // The caveat qualifies a visible number, so it appears with the amounts.
            if self.visible {
                HStack(spacing: 8) {
                    ForEach([("Codex", Palette.codex), ("Claude", Palette.claude)], id: \.0) { name, tint in
                        HStack(spacing: 4) {
                            Circle().fill(tint).frame(width: 6, height: 6)
                            Text(name)
                        }
                    }
                    Text("· at API list prices, not billed")
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .help(self.help)
            }
        }
    }

    private func metric(_ title: String, codex: Double?, claude: Double?) -> some View {
        let total: Double? = codex == nil && claude == nil ? nil : (codex ?? 0) + (claude ?? 0)
        return PrivateCostMetric(
            title: title, amount: total, explanation: self.help,
            parts: [
                .init(name: "Codex", amount: codex ?? 0, tint: Palette.codex),
                .init(name: "Claude", amount: claude ?? 0, tint: Palette.claude),
            ],
            shared: self.$visible)
    }

    private var help: String {
        var text = "API list-price estimate of Codex and Claude usage in this Mac's Codex, OMP, and Pi sessions. "
            + "Not your bill."
        let costs = [self.codex, self.claude].compactMap(\.self)
        let unpriced = costs.map(\.unpricedRecords).reduce(0, +)
        if unpriced > 0 {
            text += "\nPartial: \(unpriced) records have no known price."
        } else if costs.contains(where: \.incomplete) {
            text += "\nPartial: usage history is still being read."
        }
        return text
    }
}
