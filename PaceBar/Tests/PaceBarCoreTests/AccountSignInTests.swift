import Foundation
import SQLite3
import Testing
@testable import PaceBarCore

struct AccountSignInTests {
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func executable(_ root: URL, body: String) throws -> URL {
        let script = root.appendingPathComponent("fake-cli")
        try Data(("#!/bin/sh\n" + body).utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }

    @MainActor private func finish(_ session: AccountSignIn) async throws {
        for _ in 0..<150 where session.running {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!session.running)
    }

    @Test @MainActor func `Successful sign in waits for confirmation and duplicate identity repairs enrollment`() async throws {
        let root = try self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(
            #"{"email":"signin@example.test","https://api.openai.com/auth":{"chatgpt_plan_type":"plus"}}"#
                .utf8)
            .base64EncodedString().replacingOccurrences(of: "=", with: "")
        let script = try self.executable(
            root,
            body: """
            printf '%s' '{"tokens":{"access_token":"fixture","account_id":"identity",\
            "id_token":"header.\(payload).signature"}}' > "$CODEX_HOME/auth.json"

            """)
        let session = AccountSignIn()
        var config = Configuration()
        try session.start(AccountLoginPlan(
            provider: .codex,
            executable: script,
            home: root.appendingPathComponent("first")))
        try await self.finish(session)
        #expect(config.accounts.isEmpty)
        let candidate = try #require(session.candidates.first)
        #expect(candidate.identityHint == "signin@example.test · plus")
        try AccountDiscovery.revalidate(candidate)
        let original = try config.enroll(candidate)
        config.accounts[0].removed = true
        try session.start(AccountLoginPlan(
            provider: .codex,
            executable: script,
            home: root.appendingPathComponent("second")))
        try await self.finish(session)
        let duplicate = try #require(session.candidates.first)
        try AccountDiscovery.revalidate(duplicate)
        #expect(try config.enroll(duplicate) == original)
        #expect(config.accounts.count == 1)
        #expect(!config.accounts[0].removed)
        let changed = root.appendingPathComponent("second/auth.json")
        try Data("{\"tokens\":{\"access_token\":\"fixture\",\"account_id\":\"wrong\"}}".utf8).write(to: changed)
        #expect(throws: (any Error).self) { try AccountDiscovery.revalidate(duplicate) }
        #expect(config.accounts[0].providerAccountID == "identity")
    }

    @Test @MainActor func `Newline free prompt is visible and cancellation kills a resistant child`() async throws {
        let root = try self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = try self.executable(root, body: "trap '' TERM\nprintf 'Paste the code:'\nwhile :; do :; done\n")
        let session = AccountSignIn()
        try session.start(AccountLoginPlan(
            provider: .codex,
            executable: script,
            home: root.appendingPathComponent("home")))
        for _ in 0..<100 where !session.progress.contains("Paste the code:") {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(session.running)
        #expect(session.progress.contains("Paste the code:"))
        session.cancel()
        try await self.finish(session)
        #expect(session.candidates.isEmpty)
    }

    @Test func `Executable inspection drains oversized output rather than waiting for timeout`() async throws {
        let root = try self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = try self.executable(root, body: "/usr/bin/yes output | /usr/bin/head -c 200000\n")
        let start = Date()
        await #expect(throws: (any Error).self) { try await LoginTool.output(script, arguments: []) }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test @MainActor func `OMP login without a new local identity never offers enrollment and duplicate rows dedupe`() async throws {
        let root = try self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("agent.db")
        var handle: OpaquePointer?
        #expect(sqlite3_open(database.path, &handle) == SQLITE_OK)
        let sql = """
        CREATE TABLE auth_credentials (id INTEGER PRIMARY KEY, provider TEXT, credential_type TEXT, data TEXT, disabled_cause TEXT);
        INSERT INTO auth_credentials VALUES (1, 'anthropic', 'oauth', '{"access":"fixture","accountId":"same"}', NULL);
        INSERT INTO auth_credentials VALUES (2, 'anthropic', 'oauth', '{"access":"fixture","accountId":"same"}', NULL);
        """
        #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)
        let candidates = try ClaudeAccount.candidates(database: database)
        #expect(candidates.count == 1)
        #expect(candidates[0].source == .omp(database: database.path, credentialRowIDs: [1, 2]))
        let script = try self.executable(root, body: "exit 0\n")
        let session = AccountSignIn()
        try session.start(AccountLoginPlan(provider: .claude, executable: script, database: database))
        try await self.finish(session)
        #expect(session.candidates.isEmpty)
        #expect(session.error != nil)
    }

    @Test func `Unreadable source directory and database keep migration pending`() throws {
        let root = try self.temporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let database = root.appendingPathComponent("agent.db")
        try Data("unreadable".utf8).write(to: database)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        var config = Configuration()
        config.accountMigration = ["codex": .pending, "claude": .pending]
        let paths = try? AccountDiscovery.codexPaths(config, roots: [root.path])
        let claude = try? ClaudeAccount.candidates(database: database)
        #expect(paths == nil)
        #expect(claude == nil)
        config.migrateAccounts(codex: [], claude: [], codexReadable: paths != nil, claudeReadable: claude != nil)
        #expect(config.accountMigration["codex"] == .pending)
        #expect(config.accountMigration["claude"] == .pending)
    }

    @Test @MainActor func `Logout refuses changed identity and symlink at execution`() throws {
        let root = try self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent(".codex-pace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        let auth = home.appendingPathComponent("auth.json")
        try Data("{\"tokens\":{\"access_token\":\"fixture\",\"account_id\":\"wrong\"}}".utf8).write(to: auth)
        let script = try self.executable(root, body: "exit 0\n")
        let session = AccountSignIn()
        #expect(throws: (any Error).self) {
            try session.start(AccountLoginPlan(
                provider: .codex,
                executable: script,
                home: home,
                logout: true,
                expectedIdentity: "expected"))
        }
        let link = root.appendingPathComponent(".codex-pace-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home)
        #expect(throws: (any Error).self) {
            try session.start(AccountLoginPlan(
                provider: .codex,
                executable: script,
                home: link,
                logout: true,
                expectedIdentity: "wrong"))
        }
        #expect(!session.running)
    }
}
