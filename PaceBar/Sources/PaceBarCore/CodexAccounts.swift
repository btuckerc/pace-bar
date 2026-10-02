import Foundation

public struct CodexAccount: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let token: String
    public var identityHint = "Unknown account"
    /// When the access token stops working, if known. Selects the longest-lived copy of a sign-in.
    public var expires: Date?

    public static func parse(_ data: Data) throws -> CodexAccount {
        let auth = try Credentials.codex(data)
        guard let id = auth.account, !id.isEmpty else {
            throw UsageError.message("Codex account identity missing.")
        }
        return CodexAccount(
            id: id, label: "account", token: auth.token, identityHint: self.identityHint(data),
            expires: self.claims(auth.token).flatMap { UsageParser.number($0["exp"]) }
                .map { Date(timeIntervalSince1970: $0) })
    }

    /// OMP's Codex sign-ins, read only. OMP refreshes them during normal use, so they stay current even when the
    /// Codex home an account was enrolled from is no longer opened.
    public static func omp(database: URL = OMPCredentials.database) throws -> [CodexAccount] {
        try OMPCredentials.rows(provider: "openai-codex", database: database).compactMap { row in
            guard let data = row.data, let root = try? UsageParser.object(data),
                  let token = root["access"] as? String, !token.isEmpty,
                  let id = root["accountId"] as? String, !id.isEmpty else { return nil }
            let email = (root["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return CodexAccount(
                id: id, label: "account", token: token,
                identityHint: email.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown account",
                expires: UsageParser.number(root["expires"]).map { Date(timeIntervalSince1970: $0 / 1000) })
        }
    }

    /// Unverified JWT claims: display hints and token lifetime, never an authentication decision.
    private static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        return Data(base64Encoded: payload).flatMap { try? UsageParser.object($0) }
    }

    private static func identityHint(_ data: Data) -> String {
        guard let root = try? UsageParser.object(data),
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["id_token"] as? String,
              let claims = self.claims(token)
        else { return "Unknown account" }
        let email = (claims["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        let plan = (auth?["chatgpt_plan_type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = email.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown account"
        return plan.flatMap { $0.isEmpty ? nil : "\(identity) · \($0)" } ?? identity
    }

    /// Display names in display order, keyed by the auth-home aliases main, second, last and btc.
    public static let labels = ["Codex 1", "Codex 2", "Codex 3", "Codex 4"]

    private static func rank(_ label: String) -> Int {
        self.labels.firstIndex(of: label) ?? self.labels.count
    }

    private static func nickname(path: String, primary: Bool) -> String {
        if primary { return self.labels[0] }
        switch Configuration.expand(path).deletingLastPathComponent().lastPathComponent {
        case "second", "secondary": return self.labels[1]
        case "last": return self.labels[2]
        case "btc": return self.labels[3]
        default: return "account"
        }
    }

    /// Read existing homes only; never copy, refresh or rewrite credentials.
    public static func discover(_ configuration: Configuration) throws -> [CodexAccount] {
        try configuration.activeAccounts(.codex).map { enrollment in
            try AccountDiscovery.resolveCodex(enrollment)
        }
    }

    public static func discover(paths: [String]) throws -> [CodexAccount] {
        var accounts: [String: (CodexAccount, Date)] = [:]
        var order: [String] = []
        for path in paths where !AccountDiscovery.isAbsent(Configuration.expand(path)) {
            let label = Self.nickname(path: path, primary: path == paths.first)
            let account: CodexAccount
            do {
                let parsed = try Self.parse(Configuration.boundedRead(path))
                account = CodexAccount(
                    id: parsed.id,
                    label: label,
                    token: parsed.token,
                    identityHint: parsed.identityHint)
            } catch {
                // Keep an unreadable source visible; never substitute another identity's usage.
                account = CodexAccount(
                    id: Configuration.expand(path).path,
                    label: label,
                    token: "")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: Configuration.expand(path).path)
            let modified = attributes[.modificationDate] as? Date ?? .distantPast
            if accounts[account.id] == nil { order.append(account.id) }
            if let previous = accounts[account.id] {
                let preferredLabel = Self.rank(previous.0.label) <= Self.rank(label) ? previous.0.label : label
                let latest = modified > previous.1 ? account : previous.0
                accounts[account.id] = (
                    CodexAccount(
                        id: account.id,
                        label: preferredLabel,
                        token: latest.token,
                        identityHint: latest.identityHint),
                    max(modified, previous.1))
            } else {
                accounts[account.id] = (account, modified)
            }
        }
        guard !order.isEmpty else { throw UsageError.message("No Codex accounts found.") }
        return order.compactMap { accounts[$0]?.0 }.sorted { Self.rank($0.label) < Self.rank($1.label) }
    }
}

public struct CodexReading: Identifiable, Sendable {
    public let id: String
    public let label: String
    public var snapshot: CodexSnapshot?
    public var updated: Date?
    public var error: String?

    public init(id: String, label: String, snapshot: CodexSnapshot?, updated: Date?, error: String?) {
        self.id = id
        self.label = label
        self.snapshot = snapshot
        self.updated = updated
        self.error = error
    }
}

extension CodexReading {
    /// Resolves and reads one account. A failure keeps the last reading, marked by its error.
    public static func read(_ enrollment: AccountEnrollment, previous: CodexReading?, services: Services) async
        -> CodexReading
    {
        do {
            let account = try AccountDiscovery.resolveCodex(enrollment)
            let snapshot = try await services.codex(account: account)
            return CodexReading(
                id: enrollment.readingID, label: enrollment.label, snapshot: snapshot, updated: Date(), error: nil)
        } catch {
            return CodexReading(
                id: enrollment.readingID, label: enrollment.label, snapshot: previous?.snapshot,
                updated: previous?.updated,
                error: error is UsageError ? error.localizedDescription : "Connection unavailable")
        }
    }

    /// Accounts are independent, so they are read concurrently; the result keeps enrollment order.
    public static func read(_ enrollments: [AccountEnrollment], previous: [CodexReading], services: Services) async
        -> [CodexReading]
    {
        let previous = Dictionary(previous.map { ($0.id, $0) }) { first, _ in first }
        return await withTaskGroup(of: (Int, CodexReading).self) { group in
            for (index, enrollment) in enrollments.enumerated() {
                let prior = previous[enrollment.readingID]
                group.addTask { await (index, Self.read(enrollment, previous: prior, services: services)) }
            }
            var ordered = [CodexReading?](repeating: nil, count: enrollments.count)
            for await (index, reading) in group {
                ordered[index] = reading
            }
            return ordered.compactMap(\.self)
        }
    }
}

public enum CodexResetInventory {
    public static func total(_ readings: [CodexReading], now: Date, freshness: TimeInterval = 600) -> Int? {
        guard !readings.isEmpty, Set(readings.map(\.id)).count == readings.count else { return nil }
        var total = 0
        for reading in readings {
            guard reading.error == nil, let date = reading.updated,
                  now.timeIntervalSince(date) >= 0, now.timeIntervalSince(date) <= freshness,
                  let count = reading.snapshot?.availableResets, count >= 0, count <= 1_000_000 else { return nil }
            total += count
        }
        return total
    }
}
