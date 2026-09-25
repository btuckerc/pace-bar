import Foundation
import Testing
@testable import PaceBarCore

struct IdentityMigrationTests {
    private let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    private func write(_ relative: String, _ text: String) throws {
        let url = self.home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ relative: String) -> String? {
        (try? Data(contentsOf: self.home.appendingPathComponent(relative)))
            .flatMap { String(bytes: $0, encoding: .utf8) }
    }

    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: self.home.appendingPathComponent(relative).path)
    }

    private func legacyArchive(extra: String = "") -> String {
        """
        {"version":3,"models":[],"sessions":[],"usageBarImportedT3":true,"usageBarT3Stamp":"stamp"\(extra),
         "files":{"/tmp/a.jsonl":{"s":10,"m":1,"p":"omp","r":[],"t":[],"o":0,"gl":0,"gh":0,
         "usageBarIncomplete":true,"usageBarPendingScan":true,"usageBarScanVersion":2}}}
        """
    }

    private func seedLegacy() throws {
        try self.write(".config/usage-bar/config.json", #"{"menuBarIcon":"orbit"}"#)
        try self.write(".config/usage-bar/nested/backup.json", "backup")
        try self.write(".local/share/usage-bar/codex-cost-history.json", self.legacyArchive())
        try self.write(".local/share/usage-bar/quota-history.json", "quota")
        try self.write("Library/Caches/usage-bar/litellm-pricing.json", "prices")
    }

    @Test func `Legacy trees migrate completely with renamed archive keys and the originals kept`() throws {
        defer { try? FileManager.default.removeItem(at: self.home) }
        try self.seedLegacy()
        try IdentityMigration.run(home: self.home)
        #expect(self.read(".config/pace-bar/config.json") == #"{"menuBarIcon":"orbit"}"#)
        #expect(self.read(".config/pace-bar/nested/backup.json") == "backup")
        #expect(self.read(".local/share/pace-bar/quota-history.json") == "quota")
        #expect(self.read("Library/Caches/pace-bar/litellm-pricing.json") == "prices")
        let archive = try CodexHistoryArchive.read(
            self.home.appendingPathComponent(".local/share/pace-bar/codex-cost-history.json"))
        #expect(archive.importedT3)
        #expect(archive.t3Stamp == "stamp")
        let file = try #require(archive.files["/tmp/a.jsonl"])
        #expect(file.incomplete && file.pendingScan && file.scanVersion == 2)
        #expect(self.read(".local/share/usage-bar/codex-cost-history.json") == self.legacyArchive())
        #expect(self.exists(".config/pace-bar/.identity-migration-v1.json"))
        #expect(!IdentityMigration.pending(home: self.home))
    }

    @Test func `An existing destination wins without merging`() throws {
        defer { try? FileManager.default.removeItem(at: self.home) }
        try self.seedLegacy()
        try self.write(".local/share/pace-bar/quota-history.json", "newer")
        try IdentityMigration.run(home: self.home)
        #expect(self.read(".local/share/pace-bar/quota-history.json") == "newer")
        #expect(!self.exists(".local/share/pace-bar/codex-cost-history.json"))
        #expect(self.read(".config/pace-bar/config.json") == #"{"menuBarIcon":"orbit"}"#)
    }

    @Test func `An interrupted migration resumes and discards its unpublished staging copy`() throws {
        defer { try? FileManager.default.removeItem(at: self.home) }
        try self.seedLegacy()
        try self.write(".local/share/.pace-bar.migrating/partial.json", "partial")
        try self.write(".config/pace-bar/config.json", #"{"menuBarIcon":"orbit"}"#)
        #expect(IdentityMigration.pending(home: self.home))
        try IdentityMigration.run(home: self.home)
        #expect(!self.exists(".local/share/.pace-bar.migrating"))
        #expect(!self.exists(".local/share/pace-bar/partial.json"))
        #expect(self.read(".local/share/pace-bar/quota-history.json") == "quota")
    }

    @Test func `A completed migration never restores data deleted afterwards`() throws {
        defer { try? FileManager.default.removeItem(at: self.home) }
        try self.seedLegacy()
        try IdentityMigration.run(home: self.home)
        try FileManager.default.removeItem(at: self.home.appendingPathComponent(".local/share/pace-bar"))
        try IdentityMigration.run(home: self.home)
        #expect(!self.exists(".local/share/pace-bar"))
    }

    @Test func `A home without Usage Bar data is left untouched`() throws {
        defer { try? FileManager.default.removeItem(at: self.home) }
        try FileManager.default.createDirectory(at: self.home, withIntermediateDirectories: true)
        try IdentityMigration.run(home: self.home)
        #expect(!self.exists(".config/pace-bar"))
    }

    @Test func `A symbolic link inside a legacy tree fails without publishing that tree or a receipt`() throws {
        defer { try? FileManager.default.removeItem(at: self.home) }
        try self.seedLegacy()
        try FileManager.default.createSymbolicLink(
            atPath: self.home.appendingPathComponent(".local/share/usage-bar/link").path, withDestinationPath: "/etc")
        #expect(throws: UsageError.self) { try IdentityMigration.run(home: self.home) }
        #expect(!self.exists(".local/share/pace-bar"))
        #expect(!self.exists(".local/share/.pace-bar.migrating"))
        #expect(!self.exists(".config/pace-bar/.identity-migration-v1.json"))
        #expect(IdentityMigration.pending(home: self.home))
    }

    @Test func `An archive already holding a renamed key fails rather than choosing a value`() throws {
        defer { try? FileManager.default.removeItem(at: self.home) }
        try self.seedLegacy()
        try self.write(
            ".local/share/usage-bar/codex-cost-history.json",
            self.legacyArchive(extra: #","paceBarImportedT3":false"#))
        #expect(throws: UsageError.self) { try IdentityMigration.run(home: self.home) }
        #expect(!self.exists(".local/share/pace-bar"))
        #expect(!self.exists(".config/pace-bar/.identity-migration-v1.json"))
    }
}
