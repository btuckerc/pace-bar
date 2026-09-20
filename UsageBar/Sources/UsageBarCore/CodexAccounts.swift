import Foundation

public struct CodexAccount: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let token: String

    public static func parse(_ data: Data) throws -> CodexAccount {
        let auth = try Credentials.codex(data)
        guard let id = auth.account, !id.isEmpty else {
            throw UsageError.message("Codex account identity missing.")
        }
        return CodexAccount(id: id, label: "account", token: auth.token)
    }

    private static func rank(_ label: String) -> Int {
        ["primary", "secondary", "last", "btc"].firstIndex(of: label) ?? 4
    }

    private static func nickname(path: String, primary: Bool) -> String {
        if primary { return "primary" }
        switch Configuration.expand(path).deletingLastPathComponent().lastPathComponent {
        case "second", "secondary": return "secondary"
        case "last": return "last"
        case "btc": return "btc"
        default: return "account"
        }
    }

    /// Read existing homes only; never copy, refresh or rewrite credentials.
    public static func discover(_ configuration: Configuration) throws -> [CodexAccount] {
        var paths = [configuration.codexAuthFile]
        for root in ["~/.codex-t3", "~/.codex-gui"] {
            let directory = Configuration.expand(root)
            let children = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
            paths += children.sorted { $0.path < $1.path }.map { $0.appendingPathComponent("auth.json").path }
        }
        return try Self.discover(paths: paths)
    }

    public static func discover(paths: [String]) throws -> [CodexAccount] {
        var accounts: [String: (CodexAccount, Date)] = [:]
        var order: [String] = []
        for path in paths where FileManager.default.fileExists(atPath: Configuration.expand(path).path) {
            let label = Self.nickname(path: path, primary: path == paths.first)
            let account: CodexAccount
            do {
                let parsed = try Self.parse(Configuration.boundedRead(path))
                account = CodexAccount(id: parsed.id, label: label, token: parsed.token)
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
                    CodexAccount(id: account.id, label: preferredLabel, token: latest.token),
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
