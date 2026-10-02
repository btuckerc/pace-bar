import Foundation

/// A Claude subscription signed in through OMP. The token is only used for the read-only usage request.
public struct ClaudeAccount: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let token: String
    public let expires: Date?
    public var identityHint = "Unknown account"

    /// Reads OMP's credential store read-only; never refreshes, copies, or rewrites credentials.
    public static func discover(database: URL = OMPCredentials.database) throws -> [ClaudeAccount] {
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

    public static func candidates(database: URL = OMPCredentials.database) throws -> [AccountCandidate] {
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
        var accounts: [(ClaudeAccount, Int64)] = []
        for row in try OMPCredentials.rows(provider: "anthropic", database: database) {
            let label = "Claude \(accounts.count + 1)"
            let fallbackID = "omp-anthropic-\(row.id)"
            // Keep an unreadable sign-in visible; never substitute another identity's usage.
            let parsed = row.data.flatMap {
                try? Self.parse($0, fallbackID: fallbackID, label: label, identityKey: row.identityKey)
            }
            accounts.append((parsed ?? ClaudeAccount(id: fallbackID, label: label, token: "", expires: nil), row.id))
        }
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
