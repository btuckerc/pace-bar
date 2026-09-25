import Foundation

public struct CodexAccount: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let token: String
    public var identityHint = "Unknown account"

    public static func parse(_ data: Data) throws -> CodexAccount {
        let auth = try Credentials.codex(data)
        guard let id = auth.account, !id.isEmpty else {
            throw UsageError.message("Codex account identity missing.")
        }
        return CodexAccount(id: id, label: "account", token: auth.token, identityHint: self.identityHint(data))
    }

    /// JWT claims are an unverified display hint, never an authentication decision.
    private static func identityHint(_ data: Data) -> String {
        guard let root = try? UsageParser.object(data),
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["id_token"] as? String
        else { return "Unknown account" }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return "Unknown account" }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let decoded = Data(base64Encoded: payload),
              let claims = try? UsageParser.object(decoded)
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
