import AppKit
import SwiftUI
import UsageBarCore

struct Dashboard: View {
    @Bindable var store: UsageStore
    let openSettings: () -> Void
    @State private var isTotalSpendVisible = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                self.codexSection
                Divider().opacity(0.6)
                self.nousSection
                Divider().opacity(0.6)
                self.routerSection
            }
            .padding(18)
            Divider()
            HStack(spacing: 16) {
                Button(action: self.openSettings) { Image(systemName: "gearshape") }
                    .help("Settings").accessibilityLabel("Settings")
                if self.store.settingsError != nil {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        .help(self.store.settingsError ?? "")
                }
                Spacer()
                Button { self.store.refresh(force: true) } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh").accessibilityLabel("Refresh")
                    .disabled(!self.store.refreshing.isEmpty || self.store.paused)
                Button {
                    self.store.paused.toggle()
                    if self.store.paused { self.store.cancelRefreshes() } else { self.store.refresh(force: true) }
                } label: { Image(systemName: self.store.paused ? "play.fill" : "pause") }
                    .help(self.store.paused ? "Resume" : "Pause")
                    .accessibilityLabel(self.store.paused ? "Resume" : "Pause")
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 18).padding(.vertical, 10)
        }
        .frame(width: 390)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var codexSection: some View {
        let now = Date()
        let runway = self.store.quotaForecast.runway(
            self.store.codex,
            now: now,
            freshness: self.store.constrained ? 1800 : 600)
        let resets = self.store.errors["Codex"] == nil ? CodexResetInventory.total(
            self.store.codex, now: now, freshness: self.store.constrained ? 1800 : 600) : nil
        return VStack(alignment: .leading, spacing: 12) {
            self.heading(
                "Codex",
                provider: "Codex",
                detail: resets.map { "\($0) \($0 == 1 ? "reset" : "resets")" } ?? "— resets")
                .help(
                    "Available banked resets across all accounts. Does not count scheduled quota renewals. Unknown or stale counts show —.")
            ForEach(self.store.codex) { account in
                let stale = self.store.errors["Codex"] != nil || account.error != nil || account.updated.map {
                    Date().timeIntervalSince($0) > (self.store.constrained ? 1800 : 600)
                } ?? false
                HStack(alignment: .top, spacing: 12) {
                    HStack(spacing: 4) {
                        Text(account.label).font(.system(size: 11, weight: .medium))
                        if stale {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                                .font(.system(size: 9)).help(account.error ?? "Last reading is stale")
                        }
                    }
                    .frame(width: 70, alignment: .leading)
                    .help(self.accountHelp(account))
                    if let snapshot = account.snapshot {
                        VStack(spacing: 10) {
                            ForEach(snapshot.windows) { window in
                                let estimate = self.exhaustion(
                                    account: account,
                                    window: window,
                                    stale: stale,
                                    runway: runway,
                                    now: now)
                                VStack(spacing: 5) {
                                    HStack(spacing: 4) {
                                        Text(estimate.title).lineLimit(1)
                                            .foregroundStyle(.secondary)
                                        Spacer(minLength: 0)
                                        Text("\(window.remainingPercent, specifier: "%.0f")%").fixedSize()
                                        Text(self.reset(window.resetsAt)).foregroundStyle(.secondary).fixedSize()
                                    }
                                    .font(.system(size: 11)).monospacedDigit()
                                    self.rail(window.remainingPercent, stale: stale)
                                }
                                .help(
                                    "\(window.label): \(window.remainingPercent.formatted())% remaining. "
                                        + "Resets \(window.resetsAt.formatted()).\n" + estimate.detail)
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .opacity(stale ? 0.55 : 1)
                    } else {
                        Text("—").foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }

            if self.store.codex.isEmpty { Text("—").foregroundStyle(.secondary) }
        }
    }

    private func exhaustion(
        account: CodexReading,
        window: QuotaWindow,
        stale: Bool,
        runway: QuotaRunway,
        now: Date) -> (title: String, detail: String)
    {
        if window.lane == nil {
            return self.orderedEstimate(account: account, window: window, stale: stale, runway: runway, now: now)
        }
        let projection = self.store.quotaForecast.project(account: account.id, window: window, now: Date())
        let value: String
        let detail: String
        if stale {
            value = "—"
            detail = "Fresh account data is needed for an estimate."
        } else if window.resetsAt <= Date() {
            value = "Resetting"
            detail = "Awaiting the updated quota after its reset."
        } else if window.remainingPercent == 0 {
            value = "Capped"
            detail = "This allowance is exhausted."
        } else if let date = projection.exhaustion {
            value = "≈ " + self.forecastDate(date)
            detail = "Estimated exhaustion: \(date.formatted()). \(projection.method). Assumes this lane's pace continues."
        } else if projection.method == "Learning history" {
            value = "Learning"
            detail = "Needs two completed days with observed consumption. Uses up to 30 days, excluding today and idle days."
        } else {
            value = "To reset"
            detail = "At the observed pace this allowance lasts until its reset. \(projection.method)."
        }
        let prefix = window.lane.map { $0 == "gpt-reserve" ? "Reserve" : $0 }
            ?? (window.periodSeconds == 604_800 ? nil : window.compactLabel)
        return (
            prefix.map { "\($0) · \(value)" } ?? value,
            detail + (self.store.errors["History"].map { " \($0)" } ?? ""))
    }

    private func orderedEstimate(
        account: CodexReading,
        window: QuotaWindow,
        stale: Bool,
        runway: QuotaRunway,
        now: Date) -> (title: String, detail: String)
    {
        guard !stale else { return ("—", "Fresh account data is needed for the ordered runway.") }
        guard let entry = runway.entries[account.id] else { return ("—", runway.explanation) }
        var detail = runway.explanation + (self.store.errors["History"].map { " \($0)" } ?? "")
        let refill = entry.refills > 0 ? "↻ " : ""
        if entry.refills > 0 { detail += " This account refills before its projected depletion." }
        if entry.interrupted { detail += " Its turn is interrupted by an earlier account's refill." }
        if let start = entry.startsAt, let end = entry.exhaustsAt {
            detail += " First use: \(start.formatted()). First depletion: \(end.formatted())."
            let from = start.timeIntervalSince(now) < 1 ? "Now" : self.scheduleDay(start, now: now)
            return (refill + "≈ \(from) → \(self.forecastDate(end))", detail)
        }
        if let through = entry.coveredThrough {
            return (refill + "Through " + self.scheduleDay(through, now: now), detail)
        }
        if entry.startsAt != nil { return ("Later", detail) }
        if window
            .remainingPercent == 0 { return ("Capped", detail + " No use is scheduled before the forecast horizon.") }
        return ("Later", detail + " Not needed before the forecast horizon.")
    }

    private func scheduleDay(_ date: Date, now: Date) -> String {
        date.timeIntervalSince(now) >= 604_800
            ? date.formatted(.dateTime.month(.abbreviated).day())
            : date.formatted(.dateTime.weekday(.abbreviated))
    }

    private func forecastDate(_ date: Date) -> String {
        date.timeIntervalSinceNow >= 604_800
            ? date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    private var routerSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            self.heading("OpenRouter", provider: "OpenRouter", detail: nil)
            HStack(alignment: .top) {
                self.metric("Balance", self.money(self.store.router?.balance))
                    .help("Account-wide credit balance in USD")
                self.totalSpend
            }
            if let cap = self.store.router?.keyRemaining {
                Text("Cap \(self.money(cap))").font(.caption2).foregroundStyle(.secondary)
                    .help("Remaining spending allowance for this API key")
            }
        }
    }

    @ViewBuilder
    private var totalSpend: some View {
        if let amount = self.store.router?.totalSpent {
            VStack(alignment: .leading, spacing: 3) {
                Text("Total spent").font(.system(size: 11)).foregroundStyle(.secondary)
                Button { self.isTotalSpendVisible.toggle() } label: {
                    // Blur a fixed placeholder so hidden digits and their length never reach the view.
                    Text(self.isTotalSpendVisible ? self.money(amount) : "••••••")
                        .font(.system(size: 13, weight: .medium)).monospacedDigit()
                        .blur(radius: self.isTotalSpendVisible ? 0 : 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(self.isTotalSpendVisible ? "Hide total spent" : "Show total spent")
                .accessibilityValue(self.isTotalSpendVisible ? self.money(amount) : "Hidden")
                .help(self.isTotalSpendVisible ? "Click to hide total spent" : "Click to reveal total spent")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onDisappear { self.isTotalSpendVisible = false }
        } else {
            self.metric("Total spent", "—")
        }
    }

    private var nousSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            self.heading("nous", provider: "Nous", detail: self.store.nous?.model == nil ? "Idle" : nil)
            if let model = self.store.nous?.model {
                Text(model).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).help(model)
            }
            HStack {
                self.metric("Output", self.number(self.store.nous?.outputTokens))
                self.metric("Input", self.number(self.store.nous?.promptTokens))
                self.metric("Cache", self.number(self.store.nous?.cachedTokens))
                self.metric("t/s", self.decimal(self.store.nous?.generationTPS))
            }
            .help(
                "Token counters since model load. Input excludes cached tokens. "
                    + "t/s is llama-server's generation-rate gauge, not time to first token.")
            if let nous = self.store.nous, (nous.processing ?? 0) + (nous.queued ?? 0) > 0 {
                Text("\(self.number(nous.processing)) active · \(self.number(nous.queued)) queued")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if self.store.configuration.hostUtilization {
                HStack(spacing: 16) {
                    self.hostMeter("GPU", value: self.store.host?.gpuPercent)
                    self.hostMeter("CPU", value: self.store.cpuPercent)
                }
                HStack(alignment: .top) {
                    self.metric("GPU W", self.decimal(self.store.host?.watts)).help("Current GPU board power draw")
                    self.metric("Avg W", self.decimal(self.store.gpuEnergy.averageWatts))
                    self.metric("Wh", self.decimal(self.store.gpuEnergy.wattHours))
                    if let rate = self.store.configuration.electricityUSDPerKWh {
                        self.metric("Est. cost", self.energyCost(self.store.gpuEnergy.cost(rate: rate)))
                            .help("GPU energy × $\(rate)/kWh. Excludes the rest of the host and PSU losses.")
                    }
                }
                .help(
                    "GPU-only average power and energy since monitoring began. "
                        + "Resets when Usage Bar restarts or a counter reset is detected.")
                HStack {
                    Text("VRAM \(self.memory(self.store.host?.vramUsedMiB, self.store.host?.vramTotalMiB))")
                    Spacer()
                    Text("RAM \(self.memory(self.store.host?.ramUsedMiB, self.store.host?.ramTotalMiB))")
                    self.status("Host")
                }
                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func hostMeter(_ label: String, value: Double?) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer(minLength: 3)
                Text(value.map { "\(self.number($0))%" } ?? "—")
            }.font(.system(size: 11)).monospacedDigit()
            self.rail(value ?? 0, stale: self.store.errors["Host"] != nil)
        }
        .help("\(label) utilization. CPU is averaged between host samples.")
    }

    private func rail(_ value: Double, stale: Bool = false) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                Capsule().fill(stale ? Color.secondary : Color.accentColor)
                    .frame(width: geometry.size.width * min(100, max(0, value)) / 100)
            }
        }.frame(height: 3)
    }

    private func heading(_ title: String, provider: String, detail: String?) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            self.status(provider)
            Spacer()
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder
    private func status(_ provider: String) -> some View {
        let error = self.store.errors[provider] ?? (provider == "OpenRouter" ? self.store.router?.warning : nil)
        let date = self.store.updated[provider]
        let stale = date.map { Date().timeIntervalSince($0) > (self.store.constrained ? 1800 : 600) } ?? false
        if error != nil || stale {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 9)).foregroundStyle(Color.orange)
                .help(error ?? date.map { "Updated \($0.formatted())" } ?? "Waiting for reading")
                .accessibilityLabel(error ?? "\(provider) reading is stale")
        }
    }

    private func accountHelp(_ account: CodexReading) -> String {
        [
            account.label,
            account.snapshot?.plan?.capitalized,
            account.error,
            account.updated.map { "Updated \($0.formatted())" },
        ]
            .compactMap(\.self).joined(separator: "\n")
    }

    private func metric(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .medium)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reset(_ date: Date) -> String {
        let seconds = max(0, date.timeIntervalSinceNow)
        if seconds == 0 { return "due" }
        if seconds >= 86400 { return "\(Int(ceil(seconds / 86400)))d" }
        if seconds >= 3600 { return "\(Int(ceil(seconds / 3600)))h" }
        return "\(Int(ceil(seconds / 60)))m"
    }

    private func energyCost(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value > 0, value < 0.01 { return "<1¢" }
        return self.money(value)
    }

    private func money(_ value: Double?) -> String {
        value.map { $0.formatted(.currency(code: "USD")) } ?? "—"
    }

    private func number(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—"
    }

    private func decimal(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—"
    }

    private func memory(_ used: Double?, _ total: Double?) -> String {
        guard let used, let total else { return "—" }
        return "\(self.decimal(used / 1024))/\(self.decimal(total / 1024))G"
    }
}
