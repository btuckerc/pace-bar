import AppKit
import PaceBarCore
import SwiftUI

struct Dashboard: View {
    @Bindable var store: UsageStore
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                self.codexSection
                Divider().opacity(0.6)
                ForEach(self.store.configuration.hosts.filter(\.enabled)) { host in
                    self.nousSection(host)
                    Divider().opacity(0.6)
                }
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
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help("Quit Pace Bar").accessibilityLabel("Quit Pace Bar")
            }
            .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 18).padding(.vertical, 10)
        }
        .frame(width: 390)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var codexSection: some View {
        let now = Date()
        let freshness: TimeInterval = self.store.constrained ? 1800 : 600
        let pool = self.store.quotaForecast.pool(self.store.codex, now: now, freshness: freshness)
        let resets = self.store.errors["Codex"] == nil ? CodexResetInventory.total(
            self.store.codex, now: now, freshness: freshness) : nil
        return VStack(alignment: .leading, spacing: 12) {
            self.heading(
                "Frontier",
                provider: "Codex",
                detail: resets.map { "\($0) \($0 == 1 ? "reset" : "resets")" } ?? "— resets")
                .help("Banked resets ready to redeem across Codex accounts")
            HStack(alignment: .top, spacing: 0) {
                ForEach(self.store.codex) { account in
                    let stale = self.store.errors["Codex"] != nil || account.error != nil || account.updated.map {
                        now.timeIntervalSince($0) > freshness
                    } ?? false
                    let reason = stale ? account.error ?? self.store.errors["Codex"] ?? "Reading is out of date" : nil
                    let unused = pool.expiring[account.id].flatMap {
                        $0 >= 0.5 ? "≈ \(Int($0.rounded()))% will reset unused" : nil
                    }
                    AccountRing(
                        label: account.label,
                        outer: account.snapshot?.windows.filter { $0.lane == nil }
                            .min { $0.remainingPercent < $1.remainingPercent },
                        tint: Palette.codex,
                        staleReason: reason,
                        help: self.ringHelp(
                            title: [account.label, account.snapshot?.plan?.capitalized].compactMap(\.self)
                                .joined(separator: " · "),
                            windows: account.snapshot?.windows ?? [], notes: [unused, reason],
                            updated: account.updated, stale: stale))
                }
                if self.store.codex.isEmpty {
                    AccountRing(
                        label: "Codex", outer: nil, tint: Palette.codex, staleReason: self.store.errors["Codex"],
                        help: self.store.errors["Codex"] ?? "Waiting for a reading")
                }
                if !self.store.claude.isEmpty || self.store.errors["Claude"] != nil {
                    Divider().frame(height: 70)
                }
                ForEach(self.store.claude) { account in
                    // Anthropic rate-limits its usage endpoint, so readings are paced; up to an hour old is normal.
                    let old = account.updated.flatMap {
                        now
                            .timeIntervalSince($0) > 3600 ?
                            "Last read \($0.formatted(.relative(presentation: .named)))" : nil
                    }
                    let reason = account.error ?? self.store.errors["Claude"] ?? old
                    AccountRing(
                        label: account.label,
                        outer: account.windows?.first { $0.periodSeconds == 604_800 },
                        inner: account.windows?.first { $0.periodSeconds == 18000 },
                        tint: Palette.claude, innerTint: Palette.claudeSoft,
                        staleReason: reason,
                        help: self.ringHelp(
                            title: account.label, windows: account.windows ?? [],
                            notes: [
                                account.windows?.isEmpty == true ? "No active window" : nil,
                                account.error ?? self.store.errors["Claude"],
                            ],
                            updated: account.updated, stale: true))
                }
                if self.store.claude.isEmpty, let error = self.store.errors["Claude"] {
                    AccountRing(label: "Claude 1", outer: nil, tint: Palette.claude, staleReason: error, help: error)
                }
            }
            if !self.store.codex.isEmpty { self.poolSummary(pool) }

            APICostSummary(codex: self.store.codexCost, claude: self.store.claudeCost)
        }
    }

    private func poolSummary(_ pool: QuotaPool) -> some View {
        let forecast: String = if let end = pool.exhaustsAt {
            end.timeIntervalSinceNow < 60 ? "empty now" : "≈ lasts to \(self.forecastDate(end))"
        } else if let through = pool.coveredThrough {
            "covers past \(self.forecastDate(through))"
        } else if pool.remainingPercent != nil {
            "forecast learning"
        } else {
            "forecast unavailable"
        }
        var help: [String] = if let daily = pool.dailyConsumption {
            [
                "Your pace: \(Int(daily.rounded())) points/day over \(pool.activeDays) active days.",
                "Assumes tracked accounts run in parallel, spending soonest-resetting quota first; enrollment does not change routing.",
            ]
        } else {
            [pool.explanation]
        }
        help += self.store.codex.compactMap { account in
            pool.expiring[account.id].flatMap {
                $0 >= 0.5 ? "\(account.label): ≈ \(Int($0.rounded()))% resets unused" : nil
            }
        }
        if let error = self.store.errors["History"] { help.append(error) }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("Codex pool " + (pool.remainingPercent.map { "\(Int($0.rounded(.down)))%" } ?? "—"))
                Text(forecast).foregroundStyle(.secondary)
                Spacer()
            }
            if pool.expiringPercent >= 1 {
                Text("≈ \(Int(pool.expiringPercent.rounded()))% of the pool resets unused at your pace")
                    .foregroundStyle(.orange)
            }
        }
        .font(.system(size: 11)).monospacedDigit()
        .help(help.joined(separator: "\n"))
    }

    private func windowHelp(_ window: QuotaWindow) -> String {
        let name: String = if let lane = window.lane {
            lane == "gpt-reserve" ? "Reserve" : lane
        } else {
            switch window.periodSeconds {
            case 18000: "5-hour"
            case 604_800: "Weekly"
            default: window.compactLabel
            }
        }
        return "\(name) \(Int(window.remainingPercent.rounded(.down)))% left · resets \(self.forecastDate(window.resetsAt))"
    }

    /// Name, then each window, then only what needs attention.
    private func ringHelp(
        title: String,
        windows: [QuotaWindow],
        notes: [String?],
        updated: Date?,
        stale: Bool) -> String
    {
        let freshness = stale ? updated.map { "Updated \($0.formatted(.relative(presentation: .named)))" } : nil
        return ([title] + windows.sorted { $0.periodSeconds < $1.periodSeconds }
            .map(self.windowHelp) + notes + [freshness])
            .compactMap(\.self).joined(separator: "\n")
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
                    .help("OpenRouter credit left, account-wide")
                PrivateCostMetric(
                    title: "Spent · lifetime",
                    amount: self.store.router?.totalSpent,
                    explanation: "Actual OpenRouter credit spent, all time. Excludes BYOK provider bills.")
            }
            if let cap = self.store.router?.keyRemaining {
                Text("Cap \(self.money(cap))").font(.caption2).foregroundStyle(.secondary)
                    .help("Spending left on this API key")
            }
        }
    }

    private func nousSection(_ configuration: InferenceHost) -> some View {
        let reading = self.store.hostReadings[configuration.id] ?? HostReading()
        let nous = reading.nous
        let host = reading.hardware
        let inferenceKey = UsageStore.hostKey(configuration.id, hardware: false)
        let hardwareKey = UsageStore.hostKey(configuration.id, hardware: true)
        let hostStale = self.store.errors[hardwareKey] != nil
        let inferenceFailed = self.store.errors[inferenceKey] != nil
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(configuration.name).font(.system(size: 13, weight: .semibold))
                self.status(inferenceKey)
                if let model = nous?.model {
                    if self.store.errors[inferenceKey] == nil {
                        Circle().fill(Palette.local).frame(width: 6, height: 6).help("Model loaded")
                    }
                    Text(model).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        .truncationMode(.middle).help(model)
                }
                Spacer()
                if let pause = reading.pause {
                    // `resume_at` is the lease's hard cap; the server may return sooner.
                    Text(pause.until
                        .map { "Paused · back by \($0.formatted(date: .omitted, time: .shortened))" } ?? "Paused")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .help(pause.reason ?? "The server is temporarily unavailable")
                } else if inferenceFailed {
                    // Live host metrics mean the machine is up and only the inference server is down.
                    Text(host != nil && !hostStale ? "Server down" : "Unreachable")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .help(self.store.errors[inferenceKey] ?? "")
                } else if nous == nil {
                    Text("Waiting").font(.system(size: 11)).foregroundStyle(.secondary)
                } else if nous?.model == nil {
                    Text("Idle").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text("\(self.decimal(nous?.generationTPS)) t/s" + self.queueSummary(nous))
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .help("Generation speed reported by llama-server")
                }
            }
            if configuration.hostUtilization {
                HStack(alignment: .top, spacing: 0) {
                    MeterRing(
                        label: "GPU", value: host?.gpuPercent,
                        detail: host?.watts.map { "\(Int($0.rounded())) W" } ?? "", stale: hostStale,
                        help: host?.gpuPercent == nil ? "GPU reading unavailable"
                            : "GPU busy \(self.percent(host?.gpuPercent))"
                            + (host?.watts.map { " · drawing \(self.decimal($0)) W" } ?? ""))
                    MeterRing(
                        label: "CPU", value: reading.cpuPercent, detail: "", stale: hostStale,
                        help: reading.cpuPercent == nil ? "CPU reading unavailable"
                            : "CPU busy \(self.percent(reading.cpuPercent)), averaged since the last sample")
                    self.memoryRing("VRAM", used: host?.vramUsedMiB, total: host?.vramTotalMiB, stale: hostStale)
                    self.memoryRing("RAM", used: host?.ramUsedMiB, total: host?.ramTotalMiB, stale: hostStale)
                }
            }
            TokenBar(totals: reading.lifetime)
            if configuration.hostUtilization {
                HStack(spacing: 4) {
                    let estimated = reading.energy.isEstimated
                    Group {
                        Text("Energy").foregroundStyle(.secondary)
                        Text("\(self.number(reading.energy.wattHours)) Wh" + (estimated ? " (est.)" : ""))
                        if let average = reading.energy.averageWatts {
                            Text("avg \(Int(average.rounded())) W").foregroundStyle(.secondary)
                        }
                    }
                    .help("GPU energy recorded so far" + (estimated ? ", estimated from sampled power" : "")
                        + ". Average is between the last two samples.")
                    Spacer()
                    if let rate = configuration.electricityUSDPerKWh {
                        PrivateCostMetric(
                            title: "Cost", amount: reading.energy.cost(rate: rate),
                            explanation: "Recorded GPU energy × \(self.money(rate))/kWh", inline: true)
                    }
                    self.status(hardwareKey)
                }
                .font(.system(size: 11)).monospacedDigit()
            }
        }
    }

    private func queueSummary(_ nous: NousSnapshot?) -> String {
        let active = nous?.processing ?? 0
        let queued = nous?.queued ?? 0
        guard active + queued > 0 else { return "" }
        return " · \(self.number(active)) active" + (queued > 0 ? " · \(self.number(queued)) queued" : "")
    }

    private func memoryRing(_ label: String, used: Double?, total: Double?, stale: Bool) -> some View {
        let value: Double? = if let used, let total, total > 0 {
            min(100, used / total * 100)
        } else {
            nil
        }
        return MeterRing(
            label: label, value: value, detail: used == nil ? "" : self.memory(used, total), tint: Palette.localSoft,
            stale: stale, help: "\(label) \(self.memory(used, total)) in use")
    }

    private func percent(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))%" } ?? "—"
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
        let error = self.store.errors[provider]
            ?? self.store.errors[provider + ":history"]
            ?? (provider == "OpenRouter" ? self.store.router?.warning : nil)
        let date = self.store.updated[provider]
        let stale = date.map { Date().timeIntervalSince($0) > (self.store.constrained ? 1800 : 600) } ?? false
        if error != nil || stale {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 9)).foregroundStyle(Color.orange)
                .help(error ?? date
                    .map { "Updated \($0.formatted(.relative(presentation: .named)))" } ?? "Waiting for a reading")
                .accessibilityLabel(error ?? "\(provider) reading is stale")
        }
    }

    private func metric(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .medium)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func money(_ value: Double?) -> String {
        value.map { $0.formatted(.currency(code: "USD")) } ?? "—"
    }

    private func number(_ value: Double?, compact: Bool = false) -> String {
        value.map {
            $0.formatted(.number.locale(compact ? Locale(identifier: "en_US") : .current)
                .notation(compact ? .compactName : .automatic).precision(.fractionLength(0...(compact ? 1 : 0))))
        } ?? "—"
    }

    private func decimal(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—"
    }

    private func memory(_ used: Double?, _ total: Double?) -> String {
        guard let used, let total else { return "—" }
        return "\(self.decimal(used / 1024))/\(self.decimal(total / 1024))G"
    }
}
