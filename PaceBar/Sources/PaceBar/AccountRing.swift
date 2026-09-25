import PaceBarCore
import SwiftUI

/// One subscription as a ring, echoing the menu-bar Orbit. The outer ring is the account's main allowance;
/// an optional inner ring is a shorter session window inside it. The center shows what is usable now.
/// The tint identifies the provider and matches its share of the API-equivalent cost bar.
struct AccountRing: View {
    let label: String
    let outer: QuotaWindow?
    var inner: QuotaWindow?
    let tint: Color
    /// Tone for the nested session window; defaults to a faded primary.
    var innerTint: Color?
    /// Why the reading is stale; `nil` for a fresh reading.
    let staleReason: String?
    let help: String

    private var windows: [QuotaWindow] {
        [self.inner, self.outer].compactMap(\.self)
    }

    var body: some View {
        let stale = self.staleReason != nil
        let usable = self.windows.map(\.remainingPercent).min()
        VStack(spacing: 4) {
            ZStack {
                Self.arc(self.outer?.remainingPercent, lineWidth: 5, tint: stale ? .secondary : self.tint)
                if self.inner != nil {
                    Self.arc(
                        self.inner?.remainingPercent,
                        lineWidth: 4,
                        tint: stale ? .secondary : self.innerTint ?? self.tint.opacity(0.55))
                        .padding(7)
                }
                Text(usable.map { "\(Int($0.rounded(.down)))" } ?? "—")
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
            }
            .frame(width: 44, height: 44)
            .opacity(stale ? 0.55 : 1)
            .overlay(alignment: .topTrailing) {
                if self.staleReason != nil {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        .font(.system(size: 9))
                }
            }
            Text(self.label).font(.system(size: 10, weight: .medium)).lineLimit(1)
            Text(self.windows.isEmpty ? " " : "↻ " + self.windows.map { Self.reset($0.resetsAt) }
                .joined(separator: " · "))
                .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.label)
        .accessibilityValue(usable.map { "\(Int($0.rounded(.down)))% remaining" } ?? "Unavailable")
        .help(self.help)
    }

    static func arc(_ remaining: Double?, lineWidth: CGFloat, tint: Color) -> some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.08), lineWidth: lineWidth)
            Circle().trim(from: 0, to: min(100, max(0, remaining ?? 0)) / 100)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }

    static func reset(_ date: Date) -> String {
        let seconds = max(0, date.timeIntervalSinceNow)
        if seconds == 0 { return "due" }
        if seconds >= 86400 { return "\(Int(ceil(seconds / 86400)))d" }
        if seconds >= 3600 { return "\(Int(ceil(seconds / 3600)))h" }
        return "\(Int(ceil(seconds / 60)))m"
    }
}

/// A utilization gauge in the same ring language as the account rings.
struct MeterRing: View {
    let label: String
    /// Percentage, 0–100; `nil` when unavailable.
    let value: Double?
    let detail: String
    var tint: Color = Palette.local
    var stale = false
    let help: String

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                AccountRing.arc(self.value, lineWidth: 5, tint: self.stale ? .secondary : self.tint)
                Text(self.value.map { "\(Int($0.rounded()))" } ?? "—")
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
            }
            .frame(width: 44, height: 44)
            .opacity(self.stale ? 0.55 : 1)
            Text(self.label).font(.system(size: 10, weight: .medium))
            Text(self.detail.isEmpty ? " " : self.detail)
                .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.label)
        .accessibilityValue(self.value.map { "\(Int($0.rounded()))%" } ?? "Unavailable")
        .help(self.help)
    }
}
