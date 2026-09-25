import Foundation
import Testing
@testable import PaceBarCore

private struct OMPCostFixture {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var auth: String {
        self.home.appendingPathComponent(".codex/auth.json").path
    }

    var main: String {
        ".omp/agent/sessions/project/main.jsonl"
    }

    func message(
        _ id: String, provider: String = "openai-codex", offset: Double = 0,
        messageTime: Bool = true, usage: Bool = true) throws -> String
    {
        var message: [String: Any] = ["role": "assistant", "provider": provider, "model": "example-model"]
        if messageTime { message["timestamp"] = self.now.addingTimeInterval(offset).timeIntervalSince1970 * 1000 }
        if usage {
            message["usage"] = [
                "input": 10,
                "cacheRead": 20,
                "cacheWrite": 5,
                "output": 3,
                "reasoningTokens": 2,
                "cost": ["total": 9999],
            ] as [String: Any]
        }
        let row: [String: Any] = [
            "type": "message", "id": id,
            "timestamp": ISO8601DateFormatter().string(from: self.now.addingTimeInterval(offset)),
            "message": message,
        ]
        return try #require(String(data: JSONSerialization.data(withJSONObject: row), encoding: .utf8))
    }

    func write(_ text: String, path: String? = nil) throws {
        let file = self.home.appendingPathComponent(path ?? self.main)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: self.home.appendingPathComponent(self.main))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func pricing() throws -> APICostPricing {
        let file = self.home.appendingPathComponent("rates.json")
        let cache: [String: Any] = [
            "fetchedAt": self.now.timeIntervalSinceReferenceDate,
            "rates": ["example-model": ["input": 1.0, "output": 2.0, "cacheRead": 0.1, "cacheWrite": 0.2]],
        ]
        try JSONSerialization.data(withJSONObject: cache).write(to: file)
        return APICostPricing(cacheFile: file)
    }
}

@Test func `OMP appends and child sessions increase independent weekly and monthly prices without T3`() async throws {
    let fixture = OMPCostFixture()
    defer { try? FileManager.default.removeItem(at: fixture.home) }
    let first = try fixture.message("first")
    try fixture.write(first + "\n")
    let history = CodexCostHistory(home: fixture.home)
    let pricing = try fixture.pricing()
    let initial = await history.records(authFile: fixture.auth, now: fixture.now)
    let initialCost = await pricing.estimate(records: initial.records, incomplete: initial.incomplete, now: fixture.now)
    #expect(initialCost.usd == 19)
    #expect(initialCost.weekUSD == 19)
    #expect(initial.records.first?.tokens.input == 35)
    #expect(!initial.importedT3)

    try fixture.append(fixture.message("second") + "\n")
    try fixture.write(
        first + "\n" + fixture.message("child") + "\n",
        path: ".omp/agent/sessions/project/main/child.jsonl")
    let updated = await history.records(authFile: fixture.auth, now: fixture.now)
    let updatedCost = await pricing.estimate(records: updated.records, incomplete: updated.incomplete, now: fixture.now)
    #expect(updated.records.count == 3)
    #expect(updatedCost.usd == 57)
    #expect(updatedCost.weekUSD == 57)
    #expect(!updatedCost.incomplete)
    let restored = await CodexCostHistory(home: fixture.home).records(authFile: fixture.auth, now: fixture.now)
    let restoredCost = await pricing.estimate(
        records: restored.records,
        incomplete: restored.incomplete,
        now: fixture.now)
    #expect(restoredCost.usd == 57)
    #expect(restoredCost.weekUSD == 57)
}

@Test func `OMP unfinished tails complete once and replaced logs discard their old contribution`() async throws {
    let fixture = OMPCostFixture()
    defer { try? FileManager.default.removeItem(at: fixture.home) }
    try fixture.write(fixture.message("first"))
    let history = CodexCostHistory(home: fixture.home)
    let first = await history.records(authFile: fixture.auth, now: fixture.now)
    #expect(first.records.count == 1)
    try fixture.append("\n" + fixture.message("second") + "\n")
    let second = await history.records(authFile: fixture.auth, now: fixture.now)
    #expect(second.records.count == 2)
    let third = try fixture.message("third")
    let split = third.index(third.startIndex, offsetBy: third.count / 2)
    try fixture.append(String(third[..<split]))
    let partial = await history.records(authFile: fixture.auth, now: fixture.now)
    #expect(partial.records.count == 2)
    #expect(!partial.incomplete)
    try fixture.append(String(third[split...]) + "\n")
    let completed = await history.records(authFile: fixture.auth, now: fixture.now)
    #expect(completed.records.count == 3)
    #expect(!completed.incomplete)
    try fixture.write(fixture.message("replacement") + "\n")
    let replaced = await history.records(authFile: fixture.auth, now: fixture.now)
    #expect(replaced.records.count == 1)
    #expect(replaced.records.first?.id.contains("replacement") == true)
}

@Test func `OMP symlink roots and Pi entry timestamps preserve provider boundaries`() async throws {
    let fixture = OMPCostFixture()
    defer { try? FileManager.default.removeItem(at: fixture.home) }
    let message = try fixture.message("shared", messageTime: false)
    try fixture.write(message + "\n", path: "shared-sessions/main.jsonl")
    let agent = fixture.home.appendingPathComponent(".omp/agent")
    try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: agent.appendingPathComponent("sessions"),
        withDestinationURL: fixture.home.appendingPathComponent("shared-sessions"))
    try fixture.write([
        message,
        fixture.message("shared", provider: "openai", offset: -10, messageTime: false),
        fixture.message("anthropic", provider: "anthropic"),
        fixture.message("excluded-router", provider: "openrouter"),
        fixture.message("excluded-local", provider: "llama.cpp"),
    ].joined(separator: "\n") + "\n", path: ".pi/agent/sessions/project/main.jsonl")
    let result = await CodexCostHistory(home: fixture.home).records(authFile: fixture.auth, now: fixture.now)
    let openAI = result.records.filter { $0.vendor == .openAI }
    #expect(openAI.count == 2)
    #expect(openAI.reduce(0) { $0 + $1.tokens.input } == 70)
    #expect(result.records.count == 3)
    #expect(!result.incomplete)
}

@Test func `OMP Anthropic usage survives restarts and prices one hour cache writes at twice input`() async throws {
    let fixture = OMPCostFixture()
    defer { try? FileManager.default.removeItem(at: fixture.home) }
    let row: [String: Any] = [
        "type": "message", "id": "claude",
        "message": [
            "role": "assistant", "provider": "anthropic", "model": "example-model", "responseId": "msg_1",
            "timestamp": fixture.now.timeIntervalSince1970 * 1000,
            "usage": ["input": 4, "output": 1, "cacheRead": 10, "cacheWrite": 6, "cttl": ["ephemeral1h": 4]],
        ] as [String: Any],
    ]
    let line = try #require(String(data: JSONSerialization.data(withJSONObject: row), encoding: .utf8))
    try fixture.write(line + "\n")
    _ = await CodexCostHistory(home: fixture.home).records(authFile: fixture.auth, now: fixture.now)
    let restored = await CodexCostHistory(home: fixture.home).records(authFile: fixture.auth, now: fixture.now)
    let record = try #require(restored.records.first)
    #expect(record.vendor == .anthropic)
    #expect(record.tokens.cacheWriteLong == 4)
    // 4 input + 10 cache reads x 0.1 + 2 short writes x 0.2 + 4 long writes x 2 + 1 output x 2.
    let cost = try await fixture.pricing().estimate(records: restored.records, incomplete: false, now: fixture.now)
    #expect(abs((cost.usd ?? 0) - 15.4) < 1e-9)
}

@Test func `OMP files scanned before Anthropic support are rescanned once`() async throws {
    let fixture = OMPCostFixture()
    defer { try? FileManager.default.removeItem(at: fixture.home) }
    try fixture.write([
        fixture.message("openai"),
        fixture.message("anthropic", provider: "anthropic"),
    ].joined(separator: "\n") + "\n")
    let archiveURL = fixture.home.appendingPathComponent(".local/share/pace-bar/codex-cost-history.json")
    _ = await CodexCostHistory(home: fixture.home).records(authFile: fixture.auth, now: fixture.now)
    // Recreate the pre-upgrade archive: same checkpoint, OpenAI rows only, no scan version.
    var archive = try CodexHistoryArchive.read(archiveURL)
    for (path, var file) in archive.files {
        file.records.removeAll { $0.vendor == .anthropic }
        file.scanVersion = 1
        archive.files[path] = file
    }
    try archive.write(to: archiveURL)
    let upgraded = await CodexCostHistory(home: fixture.home).records(authFile: fixture.auth, now: fixture.now)
    #expect(upgraded.records.map(\.vendor.rawValue).sorted() == ["anthropic", "openai"])
}

@Test func `Missing OMP usage is unavailable while real usage on failed responses is retained`() async throws {
    let fixture = OMPCostFixture()
    defer { try? FileManager.default.removeItem(at: fixture.home) }
    let missing = try fixture.message("missing", usage: false)
    var failed = try #require(JSONSerialization
        .jsonObject(with: Data(fixture.message("failed").utf8)) as? [String: Any])
    var message = try #require(failed["message"] as? [String: Any])
    message["stopReason"] = "error"
    message["responseId"] = "same-response"
    failed["message"] = message
    let first = try #require(String(data: JSONSerialization.data(withJSONObject: failed), encoding: .utf8))
    failed["id"] = "copied-with-different-id"
    let copy = try #require(String(data: JSONSerialization.data(withJSONObject: failed), encoding: .utf8))
    try fixture.write(missing + "\n" + first + "\n" + copy + "\n")
    let result = await CodexCostHistory(home: fixture.home).records(authFile: fixture.auth, now: fixture.now)
    #expect(result.records.count == 1)
    #expect(result.records.first?.tokens.output == 3)
    #expect(result.incomplete)
}
