import Foundation
import Testing
@testable import PaceBarCore

struct EnergyHistoryTests {
    private func file() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("history.json")
    }

    private func remove(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent())
    }

    private func sample(
        _ wh: Double?, uptime: Double? = 100, source: HostEnergySource = .hardware,
        epoch: String? = nil) -> HostSnapshot
    {
        HostSnapshot(
            gpuPercent: nil, vramUsedMiB: nil, vramTotalMiB: nil,
            energyMilliJoules: wh.map { $0 * 3_600_000 }, uptime: uptime, watts: nil,
            ramUsedMiB: nil, ramTotalMiB: nil, cpu: nil, energySource: source, energyCounterID: epoch)
    }

    @Test func `Energy adopts available history and survives persisted restart without double counting`() async throws {
        let file = try self.file()
        defer { self.remove(file) }
        let store = NousHistoryStore(file: file)
        let first = await store.recordEnergy(self.sample(2), origin: "http://host")
        #expect(first.1)
        #expect(first.0.wattHours == 2)
        let second = await store.recordEnergy(self.sample(3, uptime: 160), origin: "http://host")
        #expect(second.0.averageWatts == 60)
        let restarted = NousHistoryStore(file: file)
        let retained = await restarted.energySnapshot(origin: "http://host")
        #expect(retained.0.wattHours == 3)
        #expect(retained.0.averageWatts == nil)
        let repeated = await restarted.recordEnergy(self.sample(3, uptime: 160), origin: "http://host")
        #expect(repeated.0.wattHours == 3)
        let continued = await restarted.recordEnergy(self.sample(4, uptime: 220), origin: "http://host")
        #expect(continued.0.wattHours == 4)
        #expect(continued.0.averageWatts == 60)
        #expect(continued.0.cost(rate: 0.15) == 0.0006)
        #expect(continued.0.cost(rate: nil) == nil)
    }

    @Test func `Driver resets retain prior energy and legacy uptime resets survive app restart`() throws {
        var energy = GPUEnergy()
        energy.record(self.sample(2, uptime: 160))
        energy.record(self.sample(0, uptime: 180))
        #expect(energy.wattHours == 2)
        #expect(energy.averageWatts == nil)
        energy.record(self.sample(1, uptime: 240))
        #expect(energy.wattHours == 3)
        #expect(energy.averageWatts == 60)
        var restarted = try JSONDecoder().decode(GPUEnergy.self, from: JSONEncoder().encode(energy))
        restarted.record(self.sample(2, uptime: 10))
        #expect(restarted.wattHours == 5)
        #expect(restarted.averageWatts == nil)
        restarted.record(self.sample(2, uptime: 10))
        #expect(restarted.wattHours == 5)
    }

    @Test func `Estimated checkpoint replay catches up without counting lost checkpoints twice`() throws {
        var energy = GPUEnergy()
        energy.record(self.sample(100, source: .estimate, epoch: "a"))
        var restarted = try JSONDecoder().decode(GPUEnergy.self, from: JSONEncoder().encode(energy))
        restarted.record(self.sample(80, uptime: 10, source: .estimate, epoch: "a"))
        restarted.record(self.sample(90, uptime: 20, source: .estimate, epoch: "a"))
        #expect(restarted.wattHours == 100)
        #expect(restarted.averageWatts == nil)
        restarted.record(self.sample(110, uptime: 30, source: .estimate, epoch: "a"))
        #expect(restarted.wattHours == 110)
        #expect(restarted.averageWatts == nil)
        restarted.record(self.sample(1, uptime: 40, source: .estimate, epoch: "b"))
        #expect(restarted.wattHours == 111)
        #expect(restarted.isEstimated)
    }

    @Test func `Switching collection methods preserves totals without importing overlapping history`() {
        var energy = GPUEnergy()
        energy.record(self.sample(100, epoch: "hardware"))
        energy.record(self.sample(80, uptime: 110, source: .estimate, epoch: "estimate"))
        #expect(energy.wattHours == 100)
        #expect(energy.averageWatts == nil)
        energy.record(self.sample(90, uptime: 120, source: .estimate, epoch: "estimate"))
        #expect(energy.wattHours == 110)
        energy.record(self.sample(200, uptime: 130, epoch: "hardware"))
        #expect(energy.wattHours == 110)
        #expect(energy.averageWatts == nil)
        energy.record(self.sample(210, uptime: 140, epoch: "hardware"))
        #expect(energy.wattHours == 120)
        #expect(energy.isEstimated)
    }

    @Test func `Adding counter identity to an older collector does not reimport its history`() {
        var energy = GPUEnergy()
        energy.record(self.sample(10))
        energy.record(self.sample(12, uptime: 160, epoch: "boot-a"))
        #expect(energy.wattHours == 12)
        energy.record(self.sample(14, uptime: 220, epoch: "boot-b"))
        #expect(energy.wattHours == 26)
        #expect(energy.averageWatts == nil)
    }

    @Test func `Missing or invalid readings retain recorded totals without invented averages`() {
        var energy = GPUEnergy()
        energy.record(self.sample(nil))
        #expect(energy.wattHours == nil)
        energy.record(self.sample(100))
        for invalid: Double? in [nil, .nan, .infinity, -1] {
            energy.record(self.sample(invalid, uptime: 160))
            #expect(energy.wattHours == 100)
            #expect(energy.averageWatts == nil)
        }
        energy.record(self.sample(110, uptime: 220))
        #expect(energy.wattHours == 110)
        #expect(energy.averageWatts == nil)
    }

    @Test func `Energy extends token-only history and stays isolated by normalized host`() async throws {
        let file = try self.file()
        defer { self.remove(file) }
        let tokens = NousSnapshot(
            model: "Example-9B", promptTokens: 100, cachedTokens: 20, outputTokens: 30,
            generationTPS: nil, promptTPS: nil, processing: nil, queued: nil, unloadedModels: [])
        let original = NousHistoryStore(file: file)
        _ = await original.record(tokens, origin: "http://host")
        let upgraded = NousHistoryStore(file: file)
        _ = await upgraded.recordEnergy(self.sample(10), origin: "HTTP://HOST:80/")
        let restarted = NousHistoryStore(file: file)
        #expect(await restarted.snapshot(origin: "http://host").0.promptTokens == 100)
        #expect(await restarted.energySnapshot(origin: "http://host").0.wattHours == 10)
        #expect(await restarted.energySnapshot(origin: "https://host").0.wattHours == nil)
        _ = await restarted.record(tokens, origin: "http://host")
        #expect(await NousHistoryStore(file: file).energySnapshot(origin: "http://host").0.wattHours == 10)
    }

    @Test func `Failed energy persistence retains the prior archive and retries the whole unsaved delta`() async throws {
        let file = try self.file()
        defer { self.remove(file) }
        let store = NousHistoryStore(file: file)
        _ = await store.recordEnergy(self.sample(1), origin: "http://host")
        let original = try Data(contentsOf: file)
        let directory = file.deletingLastPathComponent()
        let backup = directory.deletingLastPathComponent().appendingPathComponent("backup")
        try FileManager.default.moveItem(at: directory, to: backup)
        try Data("blocked directory".utf8).write(to: directory)
        let failed = await store.recordEnergy(self.sample(2, uptime: 160), origin: "http://host")
        #expect(!failed.1)
        #expect(failed.0.wattHours == 1)
        #expect(try Data(contentsOf: backup.appendingPathComponent("history.json")) == original)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: backup, to: directory)
        let recovered = await store.recordEnergy(self.sample(3, uptime: 220), origin: "http://host")
        #expect(recovered.1)
        #expect(recovered.0.wattHours == 3)
        #expect(await NousHistoryStore(file: file).energySnapshot(origin: "http://host").0.wattHours == 3)
    }

    @Test func `Corrupt persisted energy is reported rather than overwritten with a new total`() async throws {
        let file = try self.file()
        defer { self.remove(file) }
        let store = NousHistoryStore(file: file)
        _ = await store.recordEnergy(self.sample(10), origin: "http://host")
        let text = try String(contentsOf: file, encoding: .utf8)
        let corrupt = Data(text.replacingOccurrences(of: "36000000", with: "-1").utf8)
        try corrupt.write(to: file)
        let restarted = NousHistoryStore(file: file)
        let result = await restarted.recordEnergy(self.sample(20), origin: "http://host")
        #expect(!result.1)
        #expect(result.0.wattHours == nil)
        #expect(try Data(contentsOf: file) == corrupt)
    }
}
