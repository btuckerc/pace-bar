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
    /// Reading IDs with an explicit reconnect in flight.
    var reconnecting: Set<String> = []
    var paused = false
    var settingsError: String?

    @ObservationIgnored var iconNeedsUpdate: (() -> Void)?
    @ObservationIgnored let services = Services()
    @ObservationIgnored private let quotaHistory = QuotaHistoryStore()
    @ObservationIgnored let nousHistory = NousHistoryStore()
    @ObservationIgnored private let claudeUsage = ClaudeUsageTracker()
    @ObservationIgnored private let costHistory = CodexCostHistory()
    @ObservationIgnored private let costPricing = APICostPricing()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var liveTimer: Timer?
    @ObservationIgnored private var live = false
    @ObservationIgnored var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var reconnects: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var revisions: [String: Int] = [:]
    @ObservationIgnored var hostRequests = HostRequests()
    @ObservationIgnored private var sleeping = false
    @ObservationIgnored var diagnosedOutages: Set<String> = []
    @ObservationIgnored var lastPersisted: [String: Date] = [:]
    @ObservationIgnored var attempted: [String: Date] = [:]

    /// Host sampling cadence while the panel is open; the host API caches its own sample for two seconds.
    static let liveInterval: TimeInterval = 2

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

    /// While the panel is open, hosts are sampled every `liveInterval` and cloud readings older than a minute are
    /// renewed. The extra timer exists only while the panel is shown.
    func setLive(_ on: Bool) {
        guard on != self.live else { return }
        self.live = on
        self.liveTimer?.invalidate()
        self.liveTimer = nil
        guard on else { return }
        let timer = Timer(timeInterval: Self.liveInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.liveTimer = timer
        self.refresh()
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
        for task in self.reconnects.values {
            task.cancel()
        }
        self.reconnects.removeAll()
        self.reconnecting.removeAll()
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
        let constrained = self.constrained
        let cloudInterval: TimeInterval = switch (self.live, constrained) {
        case (true, false): 60
        case (true, true), (false, false): 300
        case (false, true): 900
        }
        let backgroundHostInterval: TimeInterval = constrained ? 300 : 60
        let hostInterval: TimeInterval = self.live ? (constrained ? 10 : Self.liveInterval) : backgroundHostInterval
        self.schedule("Codex", interval: cloudInterval, force: force)
        // The tracker paces Anthropic requests itself and prefers OMP's recorded readings.
        self.schedule("Claude", interval: cloudInterval, force: force)
        self.schedule("API cost", interval: constrained ? 300 : 60, force: force)
        self.schedule("OpenRouter", interval: cloudInterval, force: force)
        for host in self.configuration.hosts where host.enabled {
            self.scheduleHost(
                host, hardware: false, interval: hostInterval, retryInterval: backgroundHostInterval, force: force)
            if host.hostUtilization {
                self.scheduleHost(
                    host, hardware: true, interval: hostInterval, retryInterval: backgroundHostInterval, force: force)
            }
        }
    }

    /// Re-reads one account's sign-in and quota now, leaving the other accounts alone.
    func reconnect(_ provider: AccountProvider, id: String) {
        guard !self.paused, !self.sleeping, self.reconnects[id] == nil, self.tasks[provider.title] == nil,
              let enrollment = self.configuration.activeAccounts(provider).first(where: { $0.readingID == id })
        else { return }
        self.reconnecting.insert(id)
        let generation = self.revisions[provider.title, default: 0]
        let services = self.services
        self.reconnects[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.revisions[provider.title, default: 0] {
                    self.reconnects.removeValue(forKey: id)
                    self.reconnecting.remove(id)
                    self.iconNeedsUpdate?()
                }
            }
            switch provider {
            case .codex:
                let previous = self.codex.first { $0.id == id }
                let reading = await CodexReading.read(enrollment, previous: previous, services: services)
                guard generation == self.revisions[provider.title, default: 0], !Task.isCancelled else { return }
                if let index = self.codex.firstIndex(where: { $0.id == id }) { self.codex[index] = reading }
                guard reading.error == nil else { return }
                let (forecast, saved) = await self.quotaHistory.record([reading])
                guard generation == self.revisions[provider.title, default: 0], !Task.isCancelled else { return }
                self.quotaForecast = forecast
                self.errors["History"] = saved ? nil : "Quota history could not be saved; estimates may restart after quitting."
            case .claude:
                var reading: ClaudeReading
                do {
                    let account = try AccountDiscovery.resolveClaude(enrollment)
                    reading = await self.claudeUsage.refresh([account], force: true) {
                        try await services.claude(account: $0)
                    }[0]
                } catch {
                    let old = self.claude.first { $0.id == id }
                    reading = ClaudeReading(
                        id: id, label: enrollment.label, windows: old?.windows, updated: old?.updated,
                        error: error.localizedDescription)
                }
                guard generation == self.revisions[provider.title, default: 0], !Task.isCancelled else { return }
                if let index = self.claude.firstIndex(where: { $0.id == id }) { self.claude[index] = reading }
            }
        }
    }

    /// Whether `interval` has passed since `last`. A timer can fire a hair before a whole interval has elapsed since
    /// the previous attempt, so a wake-up within the last tenth counts as due; otherwise a 2 s cadence slips to 4 s.
    static func due(_ last: Date?, interval: TimeInterval) -> Bool {
        last.map { Date().timeIntervalSince($0) >= interval * 0.9 } ?? true
    }

    private func schedule(_ provider: String, interval: TimeInterval, force: Bool) {
        guard self.tasks[provider] == nil else { return }
        if !force, !Self.due(self.attempted[provider], interval: interval) { return }
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
                    let readings = await CodexReading.read(
                        config.activeAccounts(.codex), previous: self.codex, services: self.services)
                    guard generation == self.revisions[provider, default: 0], !Task.isCancelled else { return }
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
            self.lastPersisted.removeValue(forKey: provider)
        }
        if !changed.isDisjoint(with: AccountProvider.allCases.map(\.title)) {
            for task in self.reconnects.values {
                task.cancel()
            }
            self.reconnects.removeAll()
            self.reconnecting.removeAll()
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
