import Foundation
import Testing
@testable import PaceBarCore

private struct CostHistoryFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var auth: String {
        self.root.appendingPathComponent(".codex/auth.json").path
    }

    func line(_ type: String, _ payload: [String: Any], offset: Double = -60) throws -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let object: [String: Any] = [
            "type": type,
            "payload": payload,
            "timestamp": formatter.string(from: self.now.addingTimeInterval(offset)),
        ]
        return try #require(String(
            data: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            encoding: .utf8))
    }

    func usage(_ input: Double, total: Double? = nil, offset: Double = -30) throws -> String {
        var info: [String: Any] = ["last_token_usage": [
            "input_tokens": input,
            "cached_input_tokens": 2,
            "output_tokens": 3,
            "reasoning_output_tokens": 2,
        ]]
        if let total { info["total_token_usage"] = ["input_tokens": total, "output_tokens": total] }
        return try self.line("event_msg", ["type": "token_count", "info": info], offset: offset)
    }

    func write(_ lines: [String], path: String = ".codex/sessions/2027/01/15/a.jsonl") throws {
        let file = self.root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: self.now], ofItemAtPath: file.path)
    }
}

@Test func `Codex costs deduplicate notifications copies and shared roots without collapsing equal requests`() async throws {
    let fixture = CostHistoryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let lines = try [
        fixture.line("session_meta", ["id": "session-one"]),
        fixture.line("turn_context", ["model": "example-model"]),
        fixture.usage(10, total: 100, offset: -20.5),
        fixture.usage(10, total: 100, offset: -19.5),
        fixture.usage(11, total: 110, offset: -20.5),
        fixture.usage(10, total: 120, offset: -20.5),
    ]
    try fixture.write(lines)
    try fixture.write(lines, path: ".codex-gui/primary/archived_sessions/copy.jsonl")
    let shadow = fixture.root.appendingPathComponent(".codex-t3/primary")
    try FileManager.default.createDirectory(at: shadow.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: shadow,
        withDestinationURL: fixture.root.appendingPathComponent(".codex"))
    let result = await CodexCostHistory(home: fixture.root).records(authFile: fixture.auth, now: fixture.now)
    #expect(!result.incomplete)
    #expect(result.records.count == 3)
    #expect(result.records.reduce(0) { $0 + $1.tokens.input } == 31)
    #expect(result.records.reduce(0) { $0 + $1.tokens.output } == 9)
}

@Test func `Codex calendar windows match T3 without discarding older retained history`() async throws {
    let fixture = CostHistoryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let window = APICostWindow.bounds(now: fixture.now)
    let firstDay = window.lowerBound.timeIntervalSince(fixture.now)
    let nextDay = window.upperBound.timeIntervalSince(fixture.now)
    try fixture.write([
        fixture.line("session_meta", ["id": "boundary"]),
        fixture.line("turn_context", ["model": "example-model"]),
        fixture.usage(10, total: 10, offset: firstDay - 0.5),
        fixture.usage(11, total: 21, offset: firstDay),
        fixture.usage(12, total: 33, offset: 0),
        fixture.usage(13, total: 46, offset: nextDay + 10),
    ])
    let scanner = CodexCostHistory(home: fixture.root)
    let first = await scanner.records(authFile: fixture.auth, now: fixture.now)
    #expect(first.records.map(\.tokens.input) == [11, 12])
    #expect(first.retainedRecords == 4)
    let later = await scanner.records(authFile: fixture.auth, now: window.upperBound.addingTimeInterval(60))
    #expect(later.records.map(\.tokens.input) == [12, 13])
    #expect(later.retainedRecords == 4)
}

@Test func `Fork parent bursts are excluded and model switches price only each last request`() async throws {
    let fixture = CostHistoryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try fixture.write([
        fixture.line("session_meta", ["id": "child", "forked_from_id": "parent"], offset: -60),
        fixture.line("session_meta", ["id": "parent"], offset: -59.99),
        fixture.line("turn_context", ["model": "example-old"]),
        fixture.usage(100, total: 1000, offset: -59.9),
        fixture.line("turn_context", ["model": "example-new"], offset: -50),
        fixture.usage(10, total: 1010, offset: -49.1),
    ])
    let result = await CodexCostHistory(home: fixture.root).records(authFile: fixture.auth, now: fixture.now)
    #expect(result.records.count == 1)
    #expect(result.records.first?.model == "example-new")
    #expect(result.records.first?.tokens.input == 10)
    #expect(!result.incomplete)
}

@Test func `Changed files refresh the cache and malformed usage is reported as partial`() async throws {
    let fixture = CostHistoryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let scanner = CodexCostHistory(home: fixture.root)
    var lines = try [
        fixture.line("session_meta", ["id": "growing"]),
        fixture.line("turn_context", ["model": "example-model"]),
        fixture.usage(10, total: 10),
    ]
    try fixture.write(lines)
    let before = await scanner.records(authFile: fixture.auth, now: fixture.now)
    #expect(before.records.count == 1)
    try lines += [fixture.usage(20, total: 30, offset: -10), "{\"type\":\"token_count\",malformed"]
    try fixture.write(lines)
    let after = await scanner.records(authFile: fixture.auth, now: fixture.now)
    #expect(after.records.reduce(0) { $0 + $1.tokens.input } == 30)
    #expect(after.incomplete)
}

@Test func `Codex refreshes appended primary and newly created shadow sessions`() async throws {
    let fixture = CostHistoryFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let shadowHome = fixture.root.appendingPathComponent("shadow")
    let settingsURL = fixture.root.appendingPathComponent(".t3/userdata/settings.json")
    try FileManager.default.createDirectory(
        at: settingsURL.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    let settings: [String: Any] = [
        "providerInstances": [
            "codex": [
                "driver": "codex",
                "config": [
                    "homePath": fixture.root.appendingPathComponent(".codex").path,
                    "shadowHomePath": shadowHome.path,
                ],
            ],
        ],
    ]
    try JSONSerialization.data(withJSONObject: settings).write(to: settingsURL)
    var primaryLines = try [
        fixture.line("session_meta", ["id": "primary-session"]),
        fixture.line("turn_context", ["model": "example-model"]),
        fixture.usage(17, offset: -30),
    ]
    try fixture.write(primaryLines, path: ".codex/sessions/2027/01/15/primary.jsonl")
    let scanner = CodexCostHistory(home: fixture.root)
    let before = await scanner.records(authFile: fixture.auth, now: fixture.now)
    #expect(before.records.count == 1)
    let cacheFile = fixture.root.appendingPathComponent("rates.json")
    let cache: [String: Any] = [
        "fetchedAt": fixture.now.timeIntervalSinceReferenceDate,
        "rates": ["example-model": ["input": 1.0, "output": 2.0, "cacheRead": 0.1, "cacheWrite": 0.2]],
    ]
    try JSONSerialization.data(withJSONObject: cache).write(to: cacheFile)
    let pricing = APICostPricing(cacheFile: cacheFile)
    let beforeEstimate = await pricing.estimate(
        records: before.records, incomplete: before.incomplete, now: fixture.now)
    #expect(try abs(#require(beforeEstimate.usd) - 21.2) < 0.000001)
    #expect(beforeEstimate.pricedRecords == 1)
    try primaryLines.append(fixture.usage(23, offset: -10))
    try fixture.write(primaryLines, path: ".codex/sessions/2027/01/15/primary.jsonl")
    try fixture.write([
        fixture.line("session_meta", ["id": "shadow-session"]),
        fixture.line("turn_context", ["model": "example-model"]),
        fixture.usage(19, offset: -5),
    ], path: "shadow/sessions/2027/01/15/shadow.jsonl")
    let after = await scanner.records(authFile: fixture.auth, now: fixture.now)
    let afterEstimate = await pricing.estimate(
        records: after.records, incomplete: after.incomplete, now: fixture.now)
    #expect(after.records.count == 3)
    #expect(after.records.reduce(0) { $0 + $1.tokens.input } == 59)
    #expect(afterEstimate.pricedRecords == 3)
    #expect(try abs(#require(afterEstimate.usd) - 71.6) < 0.000001)
    #expect(!afterEstimate.incomplete)
    let restarted = CodexCostHistory(home: fixture.root)
    let restored = await restarted.records(authFile: fixture.auth, now: fixture.now)
    let restoredEstimate = await pricing.estimate(
        records: restored.records, incomplete: restored.incomplete, now: fixture.now)
    #expect(restoredEstimate.usd == afterEstimate.usd)
    let nextWeek = fixture.now.addingTimeInterval(7 * 86400)
    let weekly = await restarted.records(authFile: fixture.auth, now: nextWeek)
    #expect(weekly.records.count == 3)
    let nextMonth = fixture.now.addingTimeInterval(31 * 86400)
    let expired = await restarted.records(authFile: fixture.auth, now: nextMonth)
    #expect(expired.records.isEmpty)
    #expect(expired.retainedRecords == 3)
}
