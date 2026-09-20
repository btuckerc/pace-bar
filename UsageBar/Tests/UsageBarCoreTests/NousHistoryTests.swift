import Foundation
import Testing
@testable import UsageBarCore

struct NousHistoryTests {
    private func file() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("history.json")
    }

    private func snapshot(
        _ model: String?, prompt: Double? = nil, cached: Double? = nil, output: Double? = nil,
        unloaded: [String] = []) -> NousSnapshot
    {
        NousSnapshot(
            model: model, promptTokens: prompt, cachedTokens: cached, outputTokens: output,
            generationTPS: nil, promptTPS: nil, processing: nil, queued: nil, unloadedModels: unloaded)
    }

    @Test func `First observation seeds counters and later observations add deltas`() async throws {
        let file = try self.file()
        let store = NousHistoryStore(file: file)
        let first = await store.record(
            self.snapshot("A", prompt: 100, cached: 20, output: 40),
            origin: "http://HOST:80/")
        #expect(first.0 == NousLifetimeTotals(promptTokens: 100, cachedTokens: 20, outputTokens: 40))
        let second = await store.record(self.snapshot("A", prompt: 125, cached: 20, output: 55), origin: "http://host")
        #expect(second.0 == NousLifetimeTotals(promptTokens: 125, cachedTokens: 20, outputTokens: 55))
    }

    @Test func `Counter rollback starts a new process baseline once`() async throws {
        let file = try self.file()
        let store = NousHistoryStore(file: file)
        _ = await store.record(self.snapshot("A", prompt: 100), origin: "http://host")
        _ = await store.record(self.snapshot("A", prompt: 40), origin: "http://host")
        let repeated = await store.record(self.snapshot("A", prompt: 40), origin: "http://host")
        #expect(repeated.0.promptTokens == 140)
        let continued = await store.record(self.snapshot("A", prompt: 45), origin: "http://host")
        #expect(continued.0.promptTokens == 145)
    }

    @Test func `Model return uses its retained baseline and unloaded retirement reseeds`() async throws {
        let file = try self.file()
        let store = NousHistoryStore(file: file)
        _ = await store.record(self.snapshot("A", prompt: 100, output: 10), origin: "http://host")
        _ = await store.record(self.snapshot("B", prompt: 500, output: 50), origin: "http://host")
        _ = await store.record(self.snapshot(nil, unloaded: ["A"]), origin: "http://host")
        let returned = await store.record(self.snapshot("A", prompt: 150, output: 30), origin: "http://host")
        #expect(returned.0.promptTokens == 750)
        #expect(returned.0.outputTokens == 90)
    }

    @Test func `Missing cache remains missing and idle snapshots do not invent totals`() async throws {
        let file = try self.file()
        let store = NousHistoryStore(file: file)
        let value = await store.record(self.snapshot("A", prompt: 4, output: 2), origin: "http://host")
        #expect(value.0.cachedTokens == nil)
        let idle = await store.record(.idle, origin: "http://host")
        #expect(idle.0 == value.0)
    }

    @Test func `Hosts are normalized and isolated`() async throws {
        let file = try self.file()
        let store = NousHistoryStore(file: file)
        _ = await store.record(self.snapshot("A", prompt: 10), origin: "HTTP://HOST:80/")
        let same = await store.snapshot(origin: "http://host")
        let other = await store.snapshot(origin: "https://host")
        #expect(same.0.promptTokens == 10)
        #expect(other.0.promptTokens == nil)
    }

    @Test func `History reloads and file is private`() async throws {
        let file = try self.file()
        let first = NousHistoryStore(file: file)
        _ = await first.record(self.snapshot("A", prompt: 10), origin: "http://host")
        let second = NousHistoryStore(file: file)
        #expect(await (second.snapshot(origin: "http://host")).0.promptTokens == 10)
        #expect(try (FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?
            .intValue == 0o600)
    }

    @Test func `Corrupt history is unavailable and preserved`() async throws {
        let file = try self.file()
        let corrupt = Data("{not history".utf8)
        try corrupt.write(to: file)
        let store = NousHistoryStore(file: file)
        let result = await store.record(self.snapshot("A", prompt: 1), origin: "http://host")
        #expect(!result.1)
        #expect(try Data(contentsOf: file) == corrupt)
    }

    @Test func `Host bound fails closed without evicting history`() async throws {
        let file = try self.file()
        let store = NousHistoryStore(file: file)
        for index in 0..<16 {
            _ = await store.record(self.snapshot("A", prompt: 1), origin: "http://host\(index)")
        }
        let rejected = await store.record(self.snapshot("A", prompt: 1), origin: "http://host16")
        #expect(!rejected.1)
        #expect(await (store.snapshot(origin: "http://host0")).0.promptTokens == 1)
    }
}
