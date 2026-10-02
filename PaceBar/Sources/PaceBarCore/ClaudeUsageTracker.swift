import Foundation
import SQLite3

/// Keeps the last known Claude quota for every sign-in and requests new readings only when needed.
///
/// Anthropic rate-limits its usage endpoint aggressively. OMP already polls it while it routes requests and
/// records the result, so a recent OMP snapshot replaces a request. A 429 pauses requests for that account until
/// `Retry-After`; the last reading stays on screen and is not an error. Readings persist across launches.
public actor ClaudeUsageTracker {
    public typealias Fetch = @Sendable (ClaudeAccount) async throws -> [QuotaWindow]

    struct Snapshot: Codable, Equatable {
        var updated: Date
        var windows: [Stored]

        struct Stored: Codable, Equatable {
            let key: String
            let used: Double
            let resetsAt: Date
            /// The model of a model-scoped weekly allowance; `nil` for the shared windows.
            var lane: String?
        }
    }

    /// A snapshot this recent is used as is instead of issuing a request.
    static let reuseWindow: TimeInterval = 240
    static let defaultBackoff: TimeInterval = 600

    private let cacheFile: URL
    private let database: URL
    private var snapshots: [String: Snapshot] = [:]
    private var blockedUntil: [String: Date] = [:]
    private var loaded = false

    public init(cacheFile: URL = ClaudeUsageTracker.defaultCacheFile(), database: URL = OMPCredentials.database) {
        self.cacheFile = cacheFile
        self.database = database
    }

    public static func defaultCacheFile() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/pace-bar/claude-usage.json")
    }

    /// Last known readings without any network request.
    public func cached(_ accounts: [ClaudeAccount], now: Date = Date()) -> [ClaudeReading] {
        self.load()
        return accounts.map { self.reading($0, best: self.best($0), error: nil, now: now) }
    }

    /// `force` skips the reuse window for an explicit reconnect; a rate-limit pause still holds.
    public func refresh(
        _ accounts: [ClaudeAccount], now: Date = Date(), force: Bool = false, fetch: Fetch) async -> [ClaudeReading]
    {
        self.load()
        var readings: [ClaudeReading] = []
        for account in accounts {
            let best = self.best(account)
            if let until = self.blockedUntil[account.id], until > now {
                readings.append(self.reading(account, best: best, error: nil, now: now))
                continue
            }
            if !force, let best, now.timeIntervalSince(best.updated) < Self.reuseWindow {
                readings.append(self.reading(account, best: best, error: nil, now: now))
                continue
            }
            do {
                let windows = try await fetch(account)
                let snapshot = Snapshot(updated: now, windows: windows.compactMap(Self.store))
                self.snapshots[account.id] = snapshot
                self.blockedUntil[account.id] = nil
                self.save()
                readings.append(self.reading(account, best: snapshot, error: nil, now: now))
            } catch let UsageError.rateLimited(until) {
                self.blockedUntil[account.id] = until.map { max($0, now.addingTimeInterval(60)) }
                    ?? now.addingTimeInterval(Self.defaultBackoff)
                readings.append(self.reading(account, best: best, error: nil, now: now))
            } catch {
                let message = error is UsageError ? error.localizedDescription : "Connection unavailable"
                readings.append(self.reading(account, best: best, error: message, now: now))
            }
        }
        return readings
    }

    private func reading(_ account: ClaudeAccount, best: Snapshot?, error: String?, now: Date) -> ClaudeReading {
        ClaudeReading(
            id: account.id, label: account.label,
            windows: best.map { Self.current($0.windows, now: now) }, updated: best?.updated, error: error)
    }

    /// The newer of Pace Bar's own reading and OMP's recorded one.
    private func best(_ account: ClaudeAccount) -> Snapshot? {
        let own = self.snapshots[account.id]
        guard let omp = self.ompSnapshot(account.id) else { return own }
        guard let own else { return omp }
        return omp.updated > own.updated ? omp : own
    }

    /// A window whose reset has passed has refilled: a session has not restarted until it is used, and a
    /// weekly allowance starts a new week.
    static func current(_ stored: [Snapshot.Stored], now: Date) -> [QuotaWindow] {
        stored.compactMap { value in
            let kind: UsageParser.ClaudeWindow
            let window: (Double, Date) -> QuotaWindow
            if let lane = value.lane {
                kind = .sevenDay
                window = { UsageParser.ClaudeWindow.scoped(lane, usedPercent: $0, resetsAt: $1) }
            } else {
                guard let shared = UsageParser.ClaudeWindow(rawValue: value.key) else { return nil }
                kind = shared
                window = shared.window
            }
            guard value.resetsAt <= now else { return window(value.used, value.resetsAt) }
            guard kind == .sevenDay else { return nil }
            let periods = floor(now.timeIntervalSince(value.resetsAt) / kind.period) + 1
            return window(0, value.resetsAt.addingTimeInterval(periods * kind.period))
        }
    }

    private static func store(_ window: QuotaWindow) -> Snapshot.Stored? {
        let key = window.id.replacingOccurrences(of: "Claude-", with: "")
        if let lane = window.lane {
            return Snapshot.Stored(key: key, used: window.usedPercent, resetsAt: window.resetsAt, lane: lane)
        }
        guard UsageParser.ClaudeWindow(rawValue: key) != nil else { return nil }
        return Snapshot.Stored(key: key, used: window.usedPercent, resetsAt: window.resetsAt)
    }

    /// OMP's latest recorded quota for this account, read-only, including model-scoped weekly lanes
    /// (`anthropic:7d:<model>`, labelled `Claude 7 Day (<Model>)`).
    private func ompSnapshot(_ accountID: String) -> Snapshot? {
        guard FileManager.default.fileExists(atPath: self.database.path) else { return nil }
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(self.database.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        sqlite3_busy_timeout(handle, 500)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let query = """
        SELECT limit_id, used_fraction, resets_at, recorded_at, label FROM usage_history
        WHERE provider = 'anthropic' AND account_id = ?1
          AND (limit_id IN ('anthropic:5h', 'anthropic:7d') OR limit_id LIKE 'anthropic:7d:%')
          AND recorded_at = (SELECT max(recorded_at) FROM usage_history WHERE provider = 'anthropic' AND account_id = ?1)
        """
        guard sqlite3_prepare_v2(handle, query, -1, &statement, nil) == SQLITE_OK,
              sqlite3_bind_text(statement, 1, accountID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
              == SQLITE_OK else { return nil }
        var windows: [Snapshot.Stored] = []
        var recorded: Double?
        while sqlite3_step(statement) == SQLITE_ROW {
            guard sqlite3_column_type(statement, 1) != SQLITE_NULL, sqlite3_column_type(statement, 2) != SQLITE_NULL,
                  let limit = sqlite3_column_text(statement, 0) else { continue }
            let used = sqlite3_column_double(statement, 1) * 100
            let reset = sqlite3_column_double(statement, 2) / 1000
            recorded = sqlite3_column_double(statement, 3) / 1000
            guard used.isFinite, used >= 0, reset.isFinite else { continue }
            let resetsAt = Date(timeIntervalSince1970: reset)
            switch String(cString: limit) {
            case "anthropic:5h": windows.append(Snapshot.Stored(key: "five_hour", used: used, resetsAt: resetsAt))
            case "anthropic:7d": windows.append(Snapshot.Stored(key: "seven_day", used: used, resetsAt: resetsAt))
            case let scoped:
                let slug = String(scoped.dropFirst("anthropic:7d:".count))
                let label = sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? ""
                let named = label.range(of: #"(?<=\()[^()]{1,64}(?=\)$)"#, options: .regularExpression)
                    .map { String(label[$0]) }
                guard let model = named ?? (slug.isEmpty ? nil : slug.capitalized) else { continue }
                windows.append(Snapshot.Stored(
                    key: "seven_day:" + UsageParser.ClaudeWindow.slug(model), used: used, resetsAt: resetsAt,
                    lane: model))
            }
        }
        guard let recorded, !windows.isEmpty else { return nil }
        return Snapshot(updated: Date(timeIntervalSince1970: recorded), windows: windows)
    }

    private func load() {
        guard !self.loaded else { return }
        self.loaded = true
        guard let data = try? Data(contentsOf: self.cacheFile), data.count <= 1_048_576,
              let decoded = try? JSONDecoder().decode([String: Snapshot].self, from: data) else { return }
        self.snapshots = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(self.snapshots) else { return }
        try? FileManager.default.createDirectory(
            at: self.cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: self.cacheFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.cacheFile.path)
    }
}
