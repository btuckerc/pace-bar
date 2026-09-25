import SwiftUI

struct PrivateCostMetric: View {
    struct Part {
        let name: String
        let amount: Double
        let tint: Color
    }

    let title: String
    let amount: Double?
    let explanation: String
    /// Optional breakdown of `amount`, shown only while the amount is revealed.
    var parts: [Part] = []
    /// Title and amount on one line, for footers.
    var inline = false
    /// Reveal state shared with sibling amounts, so a pair shows and hides together.
    var shared: Binding<Bool>?
    @State private var ownVisible = false

    private var visible: Bool {
        get { self.shared?.wrappedValue ?? self.ownVisible }
        nonmutating set {
            if let shared { shared.wrappedValue = newValue } else { self.ownVisible = newValue }
        }
    }

    private static func format(_ amount: Double) -> String {
        amount > 0 && amount < 0.01 ? "<$0.01" : amount.formatted(.currency(code: "USD"))
    }

    private var split: [Part] {
        let parts = self.parts.filter { $0.amount > 0 }
        return parts.count > 1 ? parts : []
    }

    var body: some View {
        let layout = self.inline
            ? AnyLayout(HStackLayout(spacing: 4))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 3))
        layout {
            Text(self.title).font(.system(size: 11)).foregroundStyle(.secondary)
            if let amount {
                Button { self.visible.toggle() } label: {
                    // Never put private digits or their length in the hidden view or accessibility tree.
                    Text(self.visible ? Self.format(amount) : "••••••")
                        .font(.system(size: self.inline ? 11 : 13, weight: .medium)).monospacedDigit()
                        .blur(radius: self.visible ? 0 : 4)
                        .frame(maxWidth: self.inline ? nil : .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(self.visible ? "Hide" : "Show") \(self.title)")
                .accessibilityValue(self.visible ? Self.format(amount) : "Hidden")
                if self.visible, !self.split.isEmpty {
                    GeometryReader { geometry in
                        HStack(spacing: 2) {
                            ForEach(self.split.indices, id: \.self) { index in
                                let part = self.split[index]
                                Capsule().fill(part.tint)
                                    .frame(width: max(2, (geometry.size.width - 2) * part.amount / amount))
                            }
                        }
                    }
                    .frame(width: 96, height: 3)
                }
            } else {
                Text("—").font(.system(size: self.inline ? 11 : 13, weight: .medium))
            }
        }
        .frame(maxWidth: self.inline ? nil : .infinity, alignment: .leading)
        .help(self.help)
        .onDisappear { self.visible = false }
        .onChange(of: self.amount == nil) { self.visible = false }
    }

    private var help: String {
        guard self.amount != nil else { return self.explanation }
        guard self.visible else { return self.explanation + "\nClick to reveal." }
        let split = self.split.map { "\($0.name) \(Self.format($0.amount))" }.joined(separator: " · ")
        return split.isEmpty ? self.explanation : split + "\n" + self.explanation
    }
}
