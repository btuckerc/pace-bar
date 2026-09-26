import AppKit
import Observation
import PaceBarCore

@MainActor @Observable
final class UsageStore {
    var configuration = Configuration()
    var codex: [CodexReading] = []
    var claude: [ClaudeReading] = []
    var router: OpenRouterSnapshot?
    var codexCost: APICostEstimate?
    var claudeCost: APICostEstimate?
    var hostReadings: [UUID: HostReading] = [:]
    var quotaForecast = QuotaForecast()
    var errors: [String: String] = [:]
    var updated: [String: Date] = [:]
    var refreshing: Set<String> = []
    var paused = false
    var settingsError: String?

    @ObservationIgnored var iconNeedsUpdate: (() -> Void)?
    @ObservationIgnored private let services = Services()
    @ObservationIgnored private let quotaHistory = QuotaHistoryStore()
    @ObservationIgnored private let nousHistory = NousHistoryStore()
    @ObservationIgnored private let claudeUsage = ClaudeUsageTracker()
    @ObservationIgnored private let costHistory = CodexCostHistory()
    @ObservationIgnored private let costPricing = APICostPricing()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var revisions: [String: Int] = [:]
    @ObservationIgnored private var hostRequests = HostRequests()
    @ObservationIgnored private var sleeping = false
    @ObservationIgnored private var diagnosedOutages: Set<String> = []

    init(loadConfiguration: Bool = true) {
        if loadConfiguration { self.reloadConfiguration() }
    }

    var constrained: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
            || ProcessInfo.processInfo.thermalState == .serious
            || ProcessInfo.processInfo.thermalState == .critical
    }

    var quotaIconState: QuotaIconState {
        QuotaIconState(
            readings: self.codex,
            claude: self.claude,
            now: Date(),
            freshness: self.constrained ? 1800 : 600,
            unavailable: self.paused || self.sleeping || self.settingsError != nil,
            codexUnavailable: self.errors["Codex"] != nil,
            claudeUnavailable: self.errors["Claude"] != nil)
    }

    func start() {
        self.refresh()
        // One coalesced, tolerant wake-up per minute. No hidden view countdown timers.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func sleep() {
        self.sleeping = true
        self.cancelRefreshes()
    }

    func wake() {
        self.sleeping = false
        self.refresh(force: true)
    }

    func cancelRefreshes() {
        for (provider, task) in self.tasks {
            self.revisions[provider, default: 0] += 1
            task.cancel()
        }
        self.tasks.removeAll()
        self.refreshing.removeAll()
        self.iconNeedsUpdate?()
    }

    func reloadConfiguration() {
        do {
            self.configuration = try Configuration.load()
            self.projectAccounts()
            self.hostRequests.reconcile(self.configuration.hosts)
            self.settingsError = nil
        } catch {
            self.settingsError = "Could not load settings: \(error.localizedDescription)"
        }
    }

    func refresh(force: Bool = false) {
        // Reuse the existing wake-up to expire stale readings, including while paused.
        defer { self.iconNeedsUpdate?() }
        guard !self.paused, !self.sleeping, self.settingsError == nil else { return }
        let cloudInterval: TimeInterval = self.constrained ? 900 : 300
        let nousInterval: TimeInterval = self.constrained ? 300 : 60
        self.schedule("Codex", interval: cloudInterval, force: force)
        self.schedule("Claude", interval: cloudInterval, force: force)
        self.schedule("API cost", interval: self.constrained ? 300 : 60, force: force)
        self.schedule("OpenRouter", interval: cloudInterval, force: force)
        for host in self.configuration.hosts where host.enabled {
            self.scheduleHost(host, hardware: false, interval: nousInterval, force: force)
            if host.hostUtilization {
                self.scheduleHost(host, hardware: true, interval: nousInterval, force: force)
            }
        }
    }

    @ObservationIgnored private var attempted: [String: Date] = [:]

    private func schedule(_ provider: String, interval: TimeInterval, force: Bool) {
        guard self.tasks[provider] == nil else { return }
        if !force, let last = self.attempted[provider], Date().timeIntervalSince(last) < interval { return }
        self.attempted[provider] = Date()
        self.refreshing.insert(provider)
        let generation = self.revisions[provider, default: 0]
        let config = self.configuration
        self.tasks[provider] = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.revisions[provider, default: 0] {
                    self.tasks.removeValue(forKey: provider)
                    self.refreshing.remove(provider)
                    if provider == "Codex" || provider == "Claude" { self.iconNeedsUpdate?() }
                }
            }
            do {
                switch provider {
                case "Codex":
                    var readings: [CodexReading] = []
                    for enrollment in config.activeAccounts(.codex) {
                        var reading = CodexReading(
                            id: enrollment.readingID,
                            label: enrollment.label,
                            snapshot: nil,
                            updated: nil,
                            error: nil)
                        do {
                            let account = try AccountDiscovery.resolveCodex(enrollment)
                            reading.snapshot = try await self.services.codex(account: account)
                            reading.updated = Date()
                            reading.error = nil
                        } catch {
                            reading.error = error is UsageError ? error.localizedDescription : "Connection unavailable"
                        }
                        guard generation == self.revisions[provider, default: 0], !Task.isCancelled else { return }
                        readings.append(reading)
                    }
                    let (forecast, saved) = await self.quotaHistory.record(readings)
                    guard generation == self.revisions[provider, default: 0], !Task.isCancelled else { return }
                    self.quotaForecast = forecast
                    self.errors["History"] = saved ? nil : "Quota history could not be saved; estimates may restart after quitting."
                    self.codex = readings
                    self.projectAccounts()
                case "Claude":
                    var accounts: [ClaudeAccount] = []
                    var missing: [ClaudeReading] = []
                    for enrollment in config.activeAccounts(.claude) {
                        do {
                            try accounts.append(AccountDiscovery.resolveClaude(enrollment))
                        } catch {
                            missing.append(ClaudeReading(
                                id: enrollment.readingID,
                                label: enrollment.label,
                                windows: nil,
                                updated: nil,
                                error: error.localizedDescription))
                        }
                    }
                    let services = self.services
                    let readings = await self.claudeUsage.refresh(accounts) { try await services.claude(account: $0) }
                    guard generation == self.revisions[provider, default: 0], !Task.isCancelled else { return }
                    let byID = Dictionary(uniqueKeysWithValues: (readings + missing).map { ($0.id, $0) })
                    self.claude = config.activeAccounts(.claude).compactMap { byID[$0.readingID] }
                    self.projectAccounts()
                case "API cost":
                    let now = Date()
                    let history = await self.costHistory.records(codexHomes: config.codexCostHomes, now: now)
                    guard generation == self.revisions[provider, default: 0], !Task.isCancelled else { return }
                    let codex = await self.costPricing.estimate(
                        records: history.records.filter { $0.vendor == .openAI },
                        incomplete: history.incomplete, now: now)
                    let claude = await self.costPricing.estimate(
                        records: history.records.filter { $0.vendor == .anthropic },
                        incomplete: history.incomplete, now: now)
                    guard generation == self.revisions[provider, default: 0], !Task.isCancelled else { return }
                    self.codexCost = codex
                    self.claudeCost = claude
                case "OpenRouter":
                    let value = try await self.services.openRouter(config)
                    guard generation == self.revisions[provider, default: 0], !Task.isCancelled else { return }
                    self.router = value
                default: return
                }
                self.updated[provider] = Date()
                self.errors.removeValue(forKey: provider)
            } catch {
                guard generation == self.revisions[provider, default: 0], !Task.isCancelled else { return }
                // Never log raw provider bodies, token-bearing URLs or credentials.
                self.errors[provider] = error is UsageError
                    ? error.localizedDescription : "Unavailable. Check connection and credential settings."
            }
        }
    }

    static func hostKey(_ id: UUID, hardware: Bool) -> String {
        "\(id.uuidString):\(hardware ? "hardware" : "inference")"
    }

    /// Failed inference with live host metrics means the machine is up and only its server is down.
    func inferenceDownLabel(_ id: UUID) -> String {
        self.hostReadings[id]?.hardware != nil && self.errors[Self.hostKey(id, hardware: true)] == nil
            ? "Server down" : "Unreachable"
    }

    private func scheduleHost(_ host: InferenceHost, hardware: Bool, interval: TimeInterval, force: Bool) {
        let key = Self.hostKey(host.id, hardware: hardware)
        guard self.tasks[key] == nil else { return }
        // At most four host component requests in flight; the coalesced timer drains the rest.
        guard self.tasks.keys.filter({ $0.contains(":") }).count < 4 else { return }
        if !force, let last = self.attempted[key], Date().timeIntervalSince(last) < interval { return }
        // A paused server said when to come back; check every few minutes in case it resumes early.
        if !force, !hardware, let until = self.hostReadings[host.id]?.pause?.until, Date() < until,
           let last = self.attempted[key], Date().timeIntervalSince(last) < 300 { return }
        self.attempted[key] = Date()
        self.refreshing.insert(key)
        let revision = self.revisions[key, default: 0]
        let hostRevision = self.hostRequests.revision(for: host.id)
        self.tasks[key] = Task { [weak self] in
            guard let self else { return }
            @MainActor func current() -> Bool {
                revision == self.revisions[key, default: 0] && !Task.isCancelled
                    && self.hostRequests.accepts(host.id, revision: hostRevision)
            }
            defer {
                if current() {
                    self.tasks.removeValue(forKey: key)
                    self.refreshing.remove(key)
                    self.refresh()
                }
            }
            do {
                if hardware {
                    let value = try await self.services.host(host)
                    guard current() else { return }
                    let (energy, saved) = await self.nousHistory.recordEnergy(value, origin: host.serverURL)
                    guard current() else { return }
                    var reading = self.hostReadings[host.id] ?? HostReading()
                    reading.cpuPercent = value.cpu?.usage(since: reading.hardware?.cpu)
                    reading.hardware = value
                    reading.energy = energy
                    self.hostReadings[host.id] = reading
                    self.errors[key + ":history"] = saved ? nil : "Could not save GPU energy history."
                } else {
                    let (stored, loaded) = await self.nousHistory.snapshot(origin: host.serverURL)
                    guard current() else { return }
                    self.hostReadings[host.id, default: HostReading()].lifetime = stored
                    self.errors[key + ":history"] = loaded ? nil : "Could not load token history."
                    let value = try await self.services.nous(host)
                    guard current() else { return }
                    let (totals, saved) = await self.nousHistory.record(value, origin: host.serverURL)
                    guard current() else { return }
                    self.hostReadings[host.id, default: HostReading()].nous = value
                    self.hostReadings[host.id, default: HostReading()].pause = nil
                    self.hostReadings[host.id, default: HostReading()].lifetime = totals
                    self.errors[key + ":history"] = saved ? nil : "Could not save token history."
                }
                self.updated[key] = Date()
                self.errors[key] = nil
                self.diagnosedOutages.remove(key)
            } catch let UsageError.unavailable(until, reason) where !hardware {
                // An intentional pause is not an outage: no warning and no SSH diagnosis.
                guard current() else { return }
                self.hostReadings[host.id, default: HostReading()].inferencePaused(until: until, reason: reason)
                self.errors[key] = nil
                self.diagnosedOutages.remove(key)
            } catch {
                guard current() else { return }
                if !hardware { self.hostReadings[host.id, default: HostReading()].inferenceFailed() }
                // Diagnose once per outage over SSH; later failed polls keep that explanation.
                if !hardware, self.diagnosedOutages.contains(key) { return }
                self.errors[key] = error is UsageError ? error.localizedDescription : "Connection unavailable."
                if !hardware {
                    self.diagnosedOutages.insert(key)
                    let detail = await HostDoctor().diagnoseInferenceFailure(host)
                    guard current() else { return }
                    self.errors[key] = detail
                }
            }
        }
    }

    func apply(_ config: Configuration) throws {
        try Self.save(config)
        let previous = self.configuration
        var changed: Set<String> = []
        for provider in AccountProvider.allCases {
            let old = previous.activeAccounts(provider)
            let new = config.activeAccounts(provider)
            // Labels alone do not invalidate a provider request or Claude's hourly cache.
            if old.map(\.id) != new.map(\.id) || zip(old, new).contains(where: {
                $0.source != $1.source || $0.providerAccountID != $1.providerAccountID
            }) { changed.insert(provider.title) }
        }
        if previous.codexCostHomes != config.codexCostHomes { changed.insert("API cost") }
        if previous.openRouterAuthFile != config.openRouterAuthFile { changed.insert("OpenRouter") }
        for host in previous.hosts {
            let next = config.hosts.first { $0.id == host.id }
            if next != host {
                changed.formUnion([Self.hostKey(host.id, hardware: false), Self.hostKey(host.id, hardware: true)])
                if next == nil || next?.serverURL != host.serverURL {
                    self.hostReadings.removeValue(forKey: host.id)
                }
            }
        }
        for provider in changed {
            self.revisions[provider, default: 0] += 1
            self.tasks.removeValue(forKey: provider)?.cancel()
            self.refreshing.remove(provider)
            self.attempted.removeValue(forKey: provider)
            self.errors.removeValue(forKey: provider)
            self.diagnosedOutages.remove(provider)
        }
        self.hostRequests.reconcile(config.hosts)
        self.configuration = config
        self.settingsError = nil
        self.projectAccounts()
        if changed.contains("Codex") { self.quotaForecast = QuotaForecast() }
        self.refresh()
    }

    private func projectAccounts() {
        self.codex = self.configuration.activeAccounts(.codex).map { enrollment in
            let old = self.codex.first { $0.id == enrollment.readingID }
            return CodexReading(
                id: enrollment.readingID,
                label: enrollment.label,
                snapshot: old?.snapshot,
                updated: old?.updated,
                error: old?.error ?? (old == nil ? "Waiting for reading." : nil))
        }
        self.claude = self.configuration.activeAccounts(.claude).map { enrollment in
            let old = self.claude.first { $0.id == enrollment.readingID }
            return ClaudeReading(
                id: enrollment.readingID,
                label: enrollment.label,
                windows: old?.windows,
                updated: old?.updated,
                error: old?.error ?? (old == nil ? "Waiting for reading." : nil))
        }
        self.iconNeedsUpdate?()
    }

    /// Changes only the status-item drawing: no refresh, and readings stay on screen.
    func setMenuBarIcon(_ style: MenuBarIcon) throws {
        var config = self.configuration
        config.menuBarIcon = style
        try Self.save(config)
        self.configuration = config
        self.iconNeedsUpdate?()
    }

    private static func save(_ config: Configuration) throws {
        try config.save()
    }
}
