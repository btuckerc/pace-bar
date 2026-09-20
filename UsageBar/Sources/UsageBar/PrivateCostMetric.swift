import SwiftUI

struct PrivateCostMetric: View {
    let title: String
    let amount: Double?
    let explanation: String
    var estimated = false
    @State private var visible = false

    private var value: String {
        guard let amount else { return "—" }
        let formatted = amount > 0 && amount < 0.01 ? "<$0.01" : amount.formatted(.currency(code: "USD"))
        return self.estimated ? "≈ \(formatted)" : formatted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(self.title).font(.system(size: 11)).foregroundStyle(.secondary)
            if self.amount != nil {
                Button { self.visible.toggle() } label: {
                    // Never put private digits or their length in the hidden view or accessibility tree.
                    Text(self.visible ? self.value : "••••••")
                        .font(.system(size: 13, weight: .medium)).monospacedDigit()
                        .blur(radius: self.visible ? 0 : 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(self.visible ? "Hide" : "Show") \(self.title)")
                .accessibilityValue(self.visible ? self.value : "Hidden")
            } else {
                Text("—").font(.system(size: 13, weight: .medium))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(self.explanation + (self.amount == nil ? "" : "\nClick to reveal or hide."))
        .onDisappear { self.visible = false }
        .onChange(of: self.amount == nil) { self.visible = false }
    }
}
