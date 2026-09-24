import Foundation
import SQLite3

/// A Claude subscription signed in through OMP. The token is only used for the read-only usage request.
public struct ClaudeAccount: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let token: String
    public let expires: Date?

    public static var ompDatabase: URL {
        Configuration.expand("~/.omp/agent/agent.db")
    }

    /// Reads OMP's credential store read-only; never refreshes, copies, or rewrites credentials.
    public static func discover(database: URL = ClaudeAccount.ompDatabase) throws -> [ClaudeAccount] {
        guard FileManager.default.fileExists(atPath: database.path) else {
            throw UsageError.message("No OMP sign-ins found. Sign in to Claude in OMP first.")
        }
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw UsageError.message("OMP sign-ins are unreadable.")
        }
        sqlite3_busy_timeout(handle, 1000)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let query = """
        SELECT id, data FROM auth_credentials
        WHERE provider = 'anthropic' AND credential_type = 'oauth' AND disabled_cause IS NULL
        ORDER BY id
        """
        guard sqlite3_prepare_v2(handle, query, -1, &statement, nil) == SQLITE_OK else {
            throw UsageError.message("OMP sign-ins are unreadable.")
        }
        var accounts: [ClaudeAccount] = []
        var seen = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            let row = sqlite3_column_int64(statement, 0)
            let bytes = sqlite3_column_bytes(statement, 1)
            guard bytes > 0, bytes <= 1_048_576, let blob = sqlite3_column_blob(statement, 1) else { continue }
            let data = Data(bytes: blob, count: Int(bytes))
            let label = "Claude \(accounts.count + 1)"
            guard let parsed = try? Self.parse(data, fallbackID: "omp-anthropic-\(row)", label: label) else {
                // Keep an unreadable sign-in visible; never substitute another identity's usage.
                accounts.append(ClaudeAccount(id: "omp-anthropic-\(row)", label: label, token: "", expires: nil))
                continue
            }
            guard seen.insert(parsed.id).inserted else { continue }
            accounts.append(parsed)
        }
        guard !accounts.isEmpty else { throw UsageError.message("No Claude sign-in found in OMP.") }
        return accounts
    }

    static func parse(_ data: Data, fallbackID: String, label: String) throws -> ClaudeAccount {
        let root = try UsageParser.object(data)
        guard let token = root["access"] as? String, !token.isEmpty else {
            throw UsageError.message("Claude sign-in unreadable.")
        }
        let id = (root["accountId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackID
        let expires = UsageParser.number(root["expires"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        return ClaudeAccount(id: id, label: label, token: token, expires: expires)
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
