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
    var nous: NousSnapshot?
    var nousLifetime: NousLifetimeTotals?
    var host: HostSnapshot?
    var cpuPercent: Double?
    var gpuEnergy = GPUEnergy()
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
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var sleeping = false

    init() {
        self.reloadConfiguration()
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
        self.generation += 1
        for task in self.tasks.values {
            task.cancel()
        }
        self.tasks.removeAll()
        self.refreshing.removeAll()
        self.iconNeedsUpdate?()
    }

    func reloadConfiguration() {
        do {
            self.configuration = try Configuration.load()
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
        self.schedule("Nous", interval: nousInterval, force: force)
        if self.configuration.hostUtilization {
            self.schedule("Host", interval: nousInterval, force: force)
        }
    }

    @ObservationIgnored private var attempted: [String: Date] = [:]

    private func schedule(_ provider: String, interval: TimeInterval, force: Bool) {
        guard self.tasks[provider] == nil else { return }
        if !force, let last = self.attempted[provider], Date().timeIntervalSince(last) < interval { return }
        self.attempted[provider] = Date()
        self.refreshing.insert(provider)
        let generation = self.generation
        let config = self.configuration
        self.tasks[provider] = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.generation {
                    self.tasks.removeValue(forKey: provider)
                    self.refreshing.remove(provider)
                    if provider == "Codex" || provider == "Claude" { self.iconNeedsUpdate?() }
                }
            }
            do {
                switch provider {
                case "Codex":
                    let accounts = try CodexAccount.discover(config)
                    var readings: [CodexReading] = []
                    for account in accounts {
                        var reading = self.codex.first { $0.id == account.id }
                            ?? CodexReading(
                                id: account.id,
                                label: account.label,
                                snapshot: nil,
                                updated: nil,
                                error: nil)
                        do {
                            reading.snapshot = try await self.services.codex(account: account)
                            reading.updated = Date()
                            reading.error = nil
                        } catch {
                            reading.error = error is UsageError ? error.localizedDescription : "Connection unavailable"
                        }
                        guard generation == self.generation, !Task.isCancelled else { return }
                        readings.append(reading)
                    }
                    let discovered = Set(readings.map(\.id))
                    for var missing in self.codex where !discovered.contains(missing.id) {
                        missing.error = "Sign-in source missing. Last reading retained."
                        readings.append(missing)
                    }
                    let (forecast, saved) = await self.quotaHistory.record(readings)
                    guard generation == self.generation, !Task.isCancelled else { return }
                    self.quotaForecast = forecast
                    self.errors["History"] = saved ? nil : "Quota history could not be saved; estimates may restart after quitting."
                    self.codex = readings
                case "Claude":
                    let accounts = try ClaudeAccount.discover()
                    if self.claude.isEmpty {
                        // Show the last known quota at once; a request may be skipped or rate limited.
                        self.claude = await self.claudeUsage.cached(accounts)
                    }
                    let services = self.services
                    let readings = await self.claudeUsage.refresh(accounts) { try await services.claude(account: $0) }
                    guard generation == self.generation, !Task.isCancelled else { return }
                    self.claude = readings
                case "API cost":
                    let now = Date()
                    let history = await self.costHistory.records(authFile: config.codexAuthFile, now: now)
                    guard generation == self.generation, !Task.isCancelled else { return }
                    let codex = await self.costPricing.estimate(
                        records: history.records.filter { $0.vendor == .openAI },
                        incomplete: history.incomplete, now: now)
                    let claude = await self.costPricing.estimate(
                        records: history.records.filter { $0.vendor == .anthropic },
                        incomplete: history.incomplete, now: now)
                    guard generation == self.generation, !Task.isCancelled else { return }
                    self.codexCost = codex
                    self.claudeCost = claude
                case "OpenRouter":
                    let value = try await self.services.openRouter(config)
                    guard generation == self.generation else { return }
                    self.router = value
                case "Nous":
                    let origin = config.nousURL
                    let (storedTotals, stored) = await self.nousHistory.snapshot(origin: origin)
                    guard generation == self.generation, !Task.isCancelled else { return }
                    self.nousLifetime = storedTotals
                    self.errors["Nous history"] = stored ? nil : "Nous history could not be loaded; lifetime totals may be unavailable."
                    let value = try await self.services.nous(config)
                    guard generation == self.generation, !Task.isCancelled else { return }
                    let (totals, saved) = await self.nousHistory.record(value, origin: origin)
                    guard generation == self.generation, !Task.isCancelled else { return }
                    self.nousLifetime = totals
                    self.errors["Nous history"] = saved ? nil : "Could not save Nous history; totals may be lost after quitting."
                    self.nous = value
                default:
                    let (storedEnergy, stored) = await self.nousHistory.energySnapshot(origin: config.nousURL)
                    guard generation == self.generation, !Task.isCancelled else { return }
                    self.gpuEnergy = storedEnergy
                    self.errors["Host history"] = stored ? nil : "GPU energy history could not be loaded."
                    let value = try await self.services.host(config)
                    guard generation == self.generation, !Task.isCancelled else { return }
                    self.cpuPercent = value.cpu?.usage(since: self.host?.cpu)
                    let (energy, saved) = await self.nousHistory.recordEnergy(value, origin: config.nousURL)
                    guard generation == self.generation, !Task.isCancelled else { return }
                    self.gpuEnergy = energy
                    self.errors["Host history"] = saved ? nil : "Could not save GPU energy history; prior totals retained."
                    self.host = value
                }
                self.updated[provider] = Date()
                self.errors.removeValue(forKey: provider)
            } catch {
                guard generation == self.generation, !Task.isCancelled else { return }
                // Never log raw provider bodies, token-bearing URLs or credentials.
                self.errors[provider] = error is UsageError
                    ? error.localizedDescription : "Unavailable. Check connection and credential settings."
            }
        }
    }

    func apply(_ config: Configuration) throws {
        try Self.save(config)
        self.cancelRefreshes()
        self.configuration = config
        self.settingsError = nil
        self.codex = []
        self.claude = []
        self.codexCost = nil
        self.claudeCost = nil
        self.router = nil
        self.nous = nil
        self.nousLifetime = nil
        self.host = nil
        self.cpuPercent = nil
        self.gpuEnergy = GPUEnergy()
        self.updated = [:]
        self.errors = [:]
        self.attempted = [:]
        self.refresh(force: true)
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
        try config.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: Configuration.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(config).write(to: Configuration.file, options: .atomic)
    }
}
