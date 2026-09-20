import AppKit
import SwiftUI
import UsageBarCore

struct Dashboard: View {
    @Bindable var store: UsageStore
    let openSettings: () -> Void

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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Codex").font(.system(size: 13, weight: .semibold))
                self.status("Codex")
                Spacer()
                self.forecast
            }
            ForEach(self.store.codex) { account in
                let stale = account.error != nil || account.updated.map {
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
                        HStack(spacing: 12) {
                            ForEach(snapshot.windows) { window in
                                VStack(spacing: 5) {
                                    HStack(spacing: 4) {
                                        Text(window.compactLabel).lineLimit(1)
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
                                        + "Resets \(window.resetsAt.formatted()).")
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

    private var forecast: some View {
        let summary = self.store.quotaForecast.summarize(
            self.store.codex, now: Date(), freshness: self.store.constrained ? 1800 : 600)
        let title: String = if self.store.errors["Codex"] != nil {
            "Refresh needed"
        } else {
            switch summary.outcome {
            case let .exhausted(date):
                date.timeIntervalSinceNow < 60 ? "All capped now" : "All capped ≈ " + self.forecastDate(date)
            case let .resetFirst(date): "Reset first · " + self.forecastDate(date)
            case let .nextReset(date): "Next reset · " + self.forecastDate(date)
            case .insufficient: self.store.codex.isEmpty ? "Checking…" : "Refresh needed"
            }
        }
        return Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            .lineLimit(1).help(summary.details)
    }

    private func forecastDate(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    private var routerSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            self.heading("OpenRouter", provider: "OpenRouter", detail: nil)
            HStack(alignment: .top) {
                self.metric("Balance", self.money(self.store.router?.balance))
                    .help("Account-wide credit balance in USD")
                self.metric("Total spent", self.money(self.store.router?.totalSpent))
                    .help("Account-wide lifetime credit usage. Includes all keys; excludes third-party BYOK bills.")
            }
            if let cap = self.store.router?.keyRemaining {
                Text("Cap \(self.money(cap))").font(.caption2).foregroundStyle(.secondary)
                    .help("Remaining spending allowance for this API key")
            }
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

    private func status(_ provider: String) -> some View {
        let error = self.store.errors[provider] ?? (provider == "OpenRouter" ? self.store.router?.warning : nil)
        let date = self.store.updated[provider]
        let stale = date.map { Date().timeIntervalSince($0) > (self.store.constrained ? 1800 : 600) } ?? false
        return Image(systemName: error != nil || stale ? "exclamationmark.circle.fill" : "circle.fill")
            .font(.system(size: error != nil || stale ? 9 : 4))
            .foregroundStyle(error != nil || stale ? Color.orange : Color.secondary.opacity(0.4))
            .help(error ?? date.map { "Updated \($0.formatted())" } ?? "Waiting for reading")
            .accessibilityLabel(error ?? "\(provider) status")
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
