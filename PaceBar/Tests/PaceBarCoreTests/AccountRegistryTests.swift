import Foundation
import SQLite3
import Testing
@testable import PaceBarCore

struct AccountRegistryTests {
    private func candidate(_ number: Int) -> AccountCandidate {
        AccountCandidate(
            provider: .codex,
            providerAccountID: "account-\(number)",
            label: "Codex \(number)",
            source: .codexFiles(paths: ["/test/\(number)/auth.json"], managedHome: nil))
    }

    @Test func `Codex discovery decodes display claims without persisting them`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try JSONSerialization.data(withJSONObject: [
            "email": "person@example.test",
            "https://api.openai.com/auth": ["chatgpt_plan_type": "pro"],
        ]).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let auth = try JSONSerialization.data(withJSONObject: [
            "tokens": [
                "account_id": "synthetic-account",
                "access_token": "fixture",
                "id_token": "header.\(payload).unverified",
            ],
        ])
        let path = root.appendingPathComponent("auth.json")
        try auth.write(to: path)
        let candidate = try #require(AccountDiscovery.codex(paths: [path.path]).first)
        #expect(candidate.identityHint == "person@example.test · pro")
        var config = Configuration()
        try config.enroll(candidate)
        #expect(config.accounts[0].identityHint == "person@example.test · pro")
        let file = root.appendingPathComponent("config.json")
        try config.save(file: file)
        let saved = try Data(contentsOf: file)
        let json = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        let accounts = try #require(json["accounts"] as? [[String: Any]])
        #expect(accounts[0]["identityHint"] == nil)
        let savedText = try #require(String(data: saved, encoding: .utf8))
        #expect(!savedText.contains("person@example.test"))
        let restored = try JSONDecoder().decode(Configuration.self, from: saved)
        #expect(restored.accounts[0].identityHint == "Unknown account")
        #expect(restored.accounts[0].providerAccountID == "synthetic-account")
        for token in ["malformed", "header.%%%.signature", "header.e30.signature"] {
            let data = try JSONSerialization.data(withJSONObject: [
                "tokens": ["account_id": "synthetic-account", "access_token": "fixture", "id_token": token],
            ])
            #expect(try CodexAccount.parse(data).identityHint == "Unknown account")
        }
    }

    @Test func `A migrated setup drops the retired cost auth file and estimates cost from tracked accounts`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = Configuration()
        try config.enroll(self.candidate(1))
        try config.enroll(self.candidate(2))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        json["codexCostAuthFile"] = "/test/retired/auth.json"
        let file = root.appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let loaded = try Configuration.load(file: file, legacyEvidence: false)
        #expect(loaded.codexCostHomes.map(\.path) == ["/test/1", "/test/2"])
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(saved["codexCostAuthFile"] == nil)
        #expect((saved["accounts"] as? [Any])?.count == 2)
    }

    @Test func `OMP discovery reads email and identity key without changing credentials`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("agent.db")
        var handle: OpaquePointer?
        #expect(sqlite3_open(database.path, &handle) == SQLITE_OK)
        let sql = """
        CREATE TABLE auth_credentials (
            id INTEGER PRIMARY KEY, provider TEXT, credential_type TEXT, data TEXT,
            disabled_cause TEXT, identity_key TEXT);
        INSERT INTO auth_credentials VALUES
            (1, 'anthropic', 'oauth', '{"access":"fixture","accountId":"one","email":"first@example.test"}', NULL, 'fallback@example.test'),
            (2, 'anthropic', 'oauth', '{"access":"fixture","accountId":"two"}', NULL, 'second@example.test'),
            (3, 'anthropic', 'oauth', '{"access":"fixture","accountId":"three"}', NULL, '7C877880-2A43-4B97-81BC-137C97D8EA58');
        """
        #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)
        let before = try Data(contentsOf: database)
        let candidates = try ClaudeAccount.candidates(database: database)
        #expect(candidates.map(\.identityHint) == ["first@example.test", "second@example.test", "Unknown account"])
        #expect(try Data(contentsOf: database) == before)
        var config = Configuration()
        for candidate in candidates {
            try config.enroll(candidate)
        }
        let file = root.appendingPathComponent("config.json")
        try config.save(file: file)
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(!saved.contains("@example.test"))
        #expect(!saved.contains("identityHint"))
    }

    @Test func `Migration keeps legacy label order, survives restart, and never recycles labels or slots`() throws {
        var config = Configuration()
        config.accountMigration = ["codex": .pending, "claude": .pending]
        // Discovery lists auth files by path, not by their legacy label.
        config.migrateAccounts(codex: [1, 4, 3, 2].map(self.candidate), claude: [
            AccountCandidate(
                provider: .claude,
                providerAccountID: "claude-one",
                label: "Claude 1",
                source: .omp(database: "/test/agent.db", credentialRowIDs: [1])),
        ])
        let original = config.accounts
        #expect(original.map(\.label) == ["Codex 1", "Codex 2", "Codex 3", "Codex 4", "Claude 1"])
        config = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config))
        #expect(config.accounts == original)
        config.accounts[2].removed = true
        config.accounts[3].removed = true
        #expect(config.activeAccounts(.codex).map(\.label) == ["Codex 1", "Codex 2"])
        #expect(config.available((1...4).map(self.candidate), provider: .codex).isEmpty)
        try config.enroll(self.candidate(5))
        #expect(config.accounts.last?.label == "Codex 5")
        let restored = try config.enroll(self.candidate(3))
        #expect(restored == original[2].id)
        #expect(config.accounts[2].label == original[2].label)
        #expect(config.accounts[2].slot == original[2].slot)
        #expect(config.accounts.count == 6)
        try config.validate()
    }

    @Test func `Unresolved migration retains its slot and binds only the recovered source`() throws {
        var config = Configuration()
        config.accountMigration["codex"] = .pending
        var unreadable = self.candidate(2)
        unreadable = AccountCandidate(
            provider: .codex,
            providerAccountID: nil,
            label: unreadable.label,
            source: unreadable.source,
            issue: "unreadable")
        config.migrateAccounts(codex: [self.candidate(1), unreadable], claude: [])
        let unresolved = config.accounts[1]
        #expect(config.accountMigration["codex"] == .pending)
        #expect(unresolved.providerAccountID == nil)
        config.migrateAccounts(codex: [self.candidate(1), self.candidate(2)], claude: [])
        #expect(config.accounts[1].id == unresolved.id)
        #expect(config.accounts[1].providerAccountID == "account-2")
        #expect(config.accountMigration["codex"] == .complete)
        try config.validate()
    }

    @Test func `Duplicate enrollment repairs sources without doubling capacity and disabled accounts stay out`() throws {
        var config = Configuration()
        let id = try config.enroll(self.candidate(1))
        let duplicate = AccountCandidate(
            provider: .codex,
            providerAccountID: "account-1",
            label: "other",
            source: .codexFiles(paths: ["/another/auth.json"], managedHome: nil))
        #expect(try config.enroll(duplicate) == id)
        #expect(config.activeAccounts(.codex).map(\.readingID) == ["account-1"])
        config.accounts[0].enabled = false
        #expect(config.activeAccounts(.codex).isEmpty)
        #expect(config.accounts[0].label == "Codex 1")
    }

    @Test @MainActor func `Cancelled login and unreadable successful login never offer enrollment`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("fake-codex")
        try Data("#!/bin/sh\nexec /bin/sleep 5\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let session = AccountSignIn()
        try session.start(AccountLoginPlan(
            provider: .codex,
            executable: script,
            home: root.appendingPathComponent("cancelled")))
        session.cancel()
        for _ in 0..<100 where session.running {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!session.running)
        #expect(session.cancelled)
        #expect(session.candidates.isEmpty)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: script)
        try session.start(AccountLoginPlan(
            provider: .codex,
            executable: script,
            home: root.appendingPathComponent("empty")))
        for _ in 0..<100 where session.running {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!session.running)
        #expect(session.candidates.isEmpty)
        #expect(session.error != nil)
    }
}
