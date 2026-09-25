import Foundation
import Testing
@testable import PaceBarCore

@Test func `Onboarding imports every retained T3 row and survives removal of T3 and its transcripts`() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let event = CodexHistoryEvent(
        timestampMs: now.timeIntervalSince1970 * 1000, model: "example-model", sessionID: "example-session",
        tokens: APICostTokens(input: 100, cachedInput: 20, cacheWrite: 10, output: 5), reasoning: 2,
        dedupeKey: nil, reportedCost: nil)
    var old = event
    old.timestampMs -= 120 * 86400 * 1000
    let missingLog = root.appendingPathComponent("removed/sessions/a.jsonl").path
    let entry = CodexHistoryFile(
        size: 100, mtimeMs: now.timeIntervalSince1970 * 1000, provider: "codex", records: [old], tail: [event],
        offset: 50, guardLength: 50, guardHash: 42, state: CodexHistoryState(
            model: "example-model",
            sessionId: "example-session"))
    let t3File = root.appendingPathComponent(".t3/userdata/usage-scan-cache.json")
    try CodexHistoryArchive(files: [missingLog: entry]).write(to: t3File)
    let auth = root.appendingPathComponent(".codex/auth.json").path
    let first = await CodexCostHistory(home: root).records(
        codexHomes: [Configuration.expand(auth).deletingLastPathComponent()],
        now: now)
    #expect(first.importedT3)
    #expect(first.retainedRecords == 2)
    #expect(first.records.count == 1)
    #expect(first.records.first?.tokens == event.tokens)
    #expect(!first.incomplete)
    try FileManager.default.removeItem(at: root.appendingPathComponent(".t3"))
    let reloaded = await CodexCostHistory(home: root).records(
        codexHomes: [Configuration.expand(auth).deletingLastPathComponent()],
        now: now)
    #expect(reloaded.importedT3)
    #expect(reloaded.retainedRecords == 2)
    #expect(reloaded.records.first?.tokens == event.tokens)
    #expect(!reloaded.incomplete)
    let saved = root.appendingPathComponent(".local/share/pace-bar/codex-cost-history.json")
    let permissions = try FileManager.default.attributesOfItem(atPath: saved.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
}

@Test func `Archive rejects corrupt rows instead of acknowledging a lossy migration`() throws {
    let state: [String: Any] = [
        "model": "example-model", "sessionId": "s", "lastUsageSignature": NSNull(),
        "sawSessionMeta": true, "suppressingForkCopies": false, "forkCopyAnchorMs": 0,
    ]
    let row: [Any] = [1000, 0, 0, true, 0, 0, 1, 0, NSNull(), NSNull()]
    let root: [String: Any] = [
        "version": 3, "models": ["example-model"], "sessions": ["s"],
        "files": ["/example/a.jsonl": [
            "s": 10,
            "m": 1000,
            "p": "codex",
            "r": [row],
            "t": [],
            "o": 10,
            "gl": 10,
            "gh": 1,
            "cs": state,
        ]],
    ]
    let data = try JSONSerialization.data(withJSONObject: root)
    #expect(throws: (any Error).self) { try CodexHistoryArchive.decode(data) }
}

@Test func `Incremental scanning rereads an unfinished tail once and verifies replaced prefixes`() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("session.jsonl")
    let header = #"{"type":"session_meta","timestamp":"2026-09-20T10:00:00Z","payload":{"id":"s"}}"# + "\n"
        + #"{"type":"turn_context","payload":{"model":"example-model"}}"# + "\n"
    let usage = #"{"type":"event_msg","timestamp":"2026-09-20T10:00:01Z","payload":{"type":"token_count","info":{"last_token_usage":"#
        + #"{"input_tokens":10,"output_tokens":2}}}}"#
    var data = Data((header + usage).utf8)
    try data.write(to: file)
    let scanner = CodexCostScanner()
    var budget = 1_000_000
    let first = try #require(scanner.read(file: file, previous: nil, size: data.count, mtimeMs: 1, budget: &budget))
    #expect(first.records.isEmpty)
    #expect(first.tail.count == 1)
    data.append(10)
    try data.write(to: file)
    let second = try #require(scanner.read(file: file, previous: first, size: data.count, mtimeMs: 2, budget: &budget))
    #expect(second.records.count == 1)
    #expect(second.tail.isEmpty)
    #expect(second.records.first?.tokens.input == 10)
    let changedUsage = usage.replacingOccurrences(of: "\"output_tokens\":2", with: "\"output_tokens\":3")
    let changed = Data((header.replacingOccurrences(of: "example-model", with: "another-model") + changedUsage + "\n ")
        .utf8)
    try changed.write(to: file)
    let third = try #require(scanner.read(
        file: file,
        previous: second,
        size: changed.count,
        mtimeMs: 3,
        budget: &budget))
    #expect(third.records.count == 1)
    #expect(third.records.first?.model == "another-model")
    #expect(third.records.first?.tokens.output == 3)
}
