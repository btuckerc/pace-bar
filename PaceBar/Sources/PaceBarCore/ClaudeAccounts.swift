import Foundation
import SQLite3

/// A Claude subscription signed in through OMP. The token is only used for the read-only usage request.
public struct ClaudeAccount: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let token: String
    public let expires: Date?
    public var identityHint = "Unknown account"

    public static var ompDatabase: URL {
        Configuration.expand("~/.omp/agent/agent.db")
    }

    /// Reads OMP's credential store read-only; never refreshes, copies, or rewrites credentials.
    public static func discover(database: URL = ClaudeAccount.ompDatabase) throws -> [ClaudeAccount] {
        var seen = Set<String>()
        return try self.records(database: database).compactMap { record in
            guard seen.insert(record.0.id).inserted else { return nil }
            return ClaudeAccount(
                id: record.0.id,
                label: "Claude \(seen.count)",
                token: record.0.token,
                expires: record.0.expires,
                identityHint: record.0.identityHint)
        }
    }

    public static func candidates(database: URL = ClaudeAccount.ompDatabase) throws -> [AccountCandidate] {
        var result: [AccountCandidate] = []
        for (account, row) in try self.records(database: database) {
            let source = AccountSource.omp(database: database.path, credentialRowIDs: [row])
            if let index = result.firstIndex(where: { $0.providerAccountID == account.id }) {
                result[index].source = AccountDiscovery.merged(result[index].source, source)
            } else {
                result.append(AccountCandidate(
                    provider: .claude,
                    providerAccountID: account.token.isEmpty ? nil : account.id,
                    label: "Claude \(result.count + 1)",
                    source: source,
                    issue: account.token.isEmpty ? "OMP credential unreadable." : nil,
                    identityHint: account.identityHint))
            }
        }
        return result
    }

    private static func records(database: URL) throws -> [(ClaudeAccount, Int64)] {
        if AccountDiscovery.isAbsent(database) { return [] }
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw UsageError.message("OMP sign-ins are unreadable.")
        }
        sqlite3_busy_timeout(handle, 1000)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let hasIdentityKey = sqlite3_table_column_metadata(
            handle, nil, "auth_credentials", "identity_key", nil, nil, nil, nil, nil) == SQLITE_OK
        let query = """
        SELECT id, data, \(hasIdentityKey ? "identity_key" : "NULL") FROM auth_credentials
        WHERE provider = 'anthropic' AND credential_type = 'oauth' AND disabled_cause IS NULL
        ORDER BY id
        """
        guard sqlite3_prepare_v2(handle, query, -1, &statement, nil) == SQLITE_OK else {
            throw UsageError.message("OMP sign-ins are unreadable.")
        }
        var accounts: [(ClaudeAccount, Int64)] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            defer { status = sqlite3_step(statement) }
            let row = sqlite3_column_int64(statement, 0)
            let bytes = sqlite3_column_bytes(statement, 1)
            guard bytes > 0, bytes <= 1_048_576, let blob = sqlite3_column_blob(statement, 1) else {
                accounts.append((
                    ClaudeAccount(
                        id: "omp-anthropic-\(row)",
                        label: "Claude \(accounts.count + 1)",
                        token: "",
                        expires: nil),
                    row))
                continue
            }
            let data = Data(bytes: blob, count: Int(bytes))
            let identityKey = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            let label = "Claude \(accounts.count + 1)"
            guard let parsed = try? Self.parse(
                data, fallbackID: "omp-anthropic-\(row)", label: label, identityKey: identityKey)
            else {
                // Keep an unreadable sign-in visible; never substitute another identity's usage.
                accounts.append((ClaudeAccount(id: "omp-anthropic-\(row)", label: label, token: "", expires: nil), row))
                continue
            }
            accounts.append((parsed, row))
        }
        guard status == SQLITE_DONE else { throw UsageError.message("OMP sign-ins are unreadable.") }
        return accounts
    }

    static func parse(
        _ data: Data, fallbackID: String, label: String, identityKey: String? = nil) throws -> ClaudeAccount
    {
        let root = try UsageParser.object(data)
        guard let token = root["access"] as? String, !token.isEmpty else {
            throw UsageError.message("Claude sign-in unreadable.")
        }
        let id = (root["accountId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackID
        let expires = UsageParser.number(root["expires"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        let account = root["account"] as? [String: Any]
        let identity = root["identity"] as? [String: Any]
        let hints = [
            root["email"] as? String, account?["email"] as? String,
            identity?["email"] as? String, root["identity"] as? String, identityKey,
        ]
        let hint = hints.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && UUID(uuidString: $0) == nil && $0 != id } ?? "Unknown account"
        return ClaudeAccount(id: id, label: label, token: token, expires: expires, identityHint: hint)
    }
}

public struct ClaudeReading: Identifiable, Sendable {
    public let id: String
    public let label: String
    public var windows: [QuotaWindow]?
    public var updated: Date?
    public var error: String?

    public init(id: String, label: String, windows: [QuotaWindow]?, updated: Date?, error: String?) {
        self.id = id
        self.label = label
        self.windows = windows
        self.updated = updated
        self.error = error
    }
}
