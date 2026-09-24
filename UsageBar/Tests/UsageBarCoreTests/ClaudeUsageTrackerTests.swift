import Foundation
import SQLite3
import Testing
@testable import UsageBarCore

private let trackerNow = Date(timeIntervalSince1970: 1_800_000_000)
private let account = ClaudeAccount(id: "acct", label: "Claude 1", token: "token", expires: nil)

private final class FetchLog: @unchecked Sendable {
    var calls = 0
    var result: Result<[QuotaWindow], UsageError> = .success([])
}

private func windows(session: Double, week: Double) -> [QuotaWindow] {
    [
        UsageParser.ClaudeWindow.fiveHour.window(usedPercent: session, resetsAt: trackerNow.addingTimeInterval(3600)),
        UsageParser.ClaudeWindow.sevenDay.window(usedPercent: week, resetsAt: trackerNow.addingTimeInterval(86400)),
    ]
}

private func temporary(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
}

private func tracker(cache: URL, database: URL = temporary("missing.db")) -> ClaudeUsageTracker {
    ClaudeUsageTracker(cacheFile: cache, database: database)
}

private func fetch(_ log: FetchLog) -> ClaudeUsageTracker.Fetch {
    { _ in
        log.calls += 1
        return try log.result.get()
    }
}

@Test func `Rate limits keep the last reading without an error and pause requests until Retry-After`() async {
    let cache = temporary("claude.json")
    defer { try? FileManager.default.removeItem(at: cache) }
    let usage = tracker(cache: cache)
    let log = FetchLog()
    log.result = .success(windows(session: 10, week: 20))
    _ = await usage.refresh([account], now: trackerNow, fetch: fetch(log))

    log.result = .failure(.rateLimited(until: trackerNow.addingTimeInterval(1800)))
    let limited = await usage.refresh([account], now: trackerNow.addingTimeInterval(300), fetch: fetch(log))
    #expect(limited[0].error == nil)
    #expect(limited[0].windows?.map(\.usedPercent) == [10, 20])
    #expect(limited[0].updated == trackerNow)

    _ = await usage.refresh([account], now: trackerNow.addingTimeInterval(1500), fetch: fetch(log))
    #expect(log.calls == 2)
    log.result = .success(windows(session: 30, week: 40))
    let resumed = await usage.refresh([account], now: trackerNow.addingTimeInterval(1900), fetch: fetch(log))
    #expect(log.calls == 3)
    #expect(resumed[0].windows?.map(\.usedPercent) == [30, 40])
}

@Test func `The last reading survives a relaunch and a recent one is reused instead of requested`() async {
    let cache = temporary("claude.json")
    defer { try? FileManager.default.removeItem(at: cache) }
    let log = FetchLog()
    log.result = .success(windows(session: 10, week: 20))
    _ = await tracker(cache: cache).refresh([account], now: trackerNow, fetch: fetch(log))

    let relaunched = tracker(cache: cache)
    #expect(await relaunched.cached([account], now: trackerNow)[0].windows?.map(\.usedPercent) == [10, 20])
    _ = await relaunched.refresh([account], now: trackerNow.addingTimeInterval(60), fetch: fetch(log))
    #expect(log.calls == 1)
}

@Test func `A newer OMP reading replaces a request`() async {
    let cache = temporary("claude.json")
    let database = temporary("agent.db")
    defer {
        try? FileManager.default.removeItem(at: cache)
        try? FileManager.default.removeItem(at: database)
    }
    var handle: OpaquePointer?
    #expect(sqlite3_open(database.path, &handle) == SQLITE_OK)
    let recorded = Int(trackerNow.timeIntervalSince1970 * 1000) - 60000
    let reset = Int(trackerNow.timeIntervalSince1970 * 1000) + 3_600_000
    let sql = """
    CREATE TABLE usage_history (provider TEXT, account_id TEXT, limit_id TEXT, used_fraction REAL,
      resets_at INTEGER, recorded_at INTEGER);
    INSERT INTO usage_history VALUES ('anthropic', 'acct', 'anthropic:5h', 0.25, \(reset), \(recorded));
    INSERT INTO usage_history VALUES ('anthropic', 'acct', 'anthropic:7d', 0.5, \(reset), \(recorded));
    INSERT INTO usage_history VALUES ('anthropic', 'other', 'anthropic:5h', 0.99, \(reset), \(recorded + 1));
    """
    #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(handle)
    let log = FetchLog()
    let readings = await tracker(cache: cache, database: database).refresh(
        [account],
        now: trackerNow,
        fetch: fetch(log))
    #expect(log.calls == 0)
    #expect(readings[0].windows?.map(\.usedPercent) == [25, 50])
}

@Test func `Readings past a reset show the refilled allowance`() {
    let stored = [
        ClaudeUsageTracker.Snapshot.Stored(key: "five_hour", used: 80, resetsAt: trackerNow.addingTimeInterval(-60)),
        ClaudeUsageTracker.Snapshot.Stored(key: "seven_day", used: 90, resetsAt: trackerNow.addingTimeInterval(-60)),
    ]
    let current = ClaudeUsageTracker.current(stored, now: trackerNow)
    #expect(current.count == 1)
    #expect(current[0].usedPercent == 0)
    #expect(current[0].resetsAt == trackerNow.addingTimeInterval(604_800 - 60))
}

@Test func `Retry-After accepts delay seconds and HTTP dates`() {
    #expect(Services.retryAfter("120", now: trackerNow) == trackerNow.addingTimeInterval(120))
    #expect(Services.retryAfter("Fri, 15 Jan 2027 08:05:00 GMT", now: trackerNow)
        == Date(timeIntervalSince1970: 1_800_000_300))
    #expect(Services.retryAfter("soon", now: trackerNow) == nil)
}
