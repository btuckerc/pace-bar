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
        let root = try UsageParser.object(data)
        let tokens = root["tokens"] as? [String: Any] ?? [:]
        let jwt = (tokens["id_token"] as? String ?? "").split(separator: ".")
        var label = String(id.prefix(8))
        if jwt.count == 3 {
            var encoded = String(jwt[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(
                of: "_",
                with: "/")
            encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            if let payload = Data(base64Encoded: encoded),
               let claims = try? UsageParser.object(payload), let email = claims["email"] as? String
            { label = email }
        }
        return CodexAccount(id: id, label: label, token: auth.token)
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
            let account: CodexAccount
            do {
                account = try Self.parse(Configuration.boundedRead(path))
            } catch {
                // Keep an unreadable source visible; never substitute another identity's usage.
                account = CodexAccount(
                    id: Configuration.expand(path).path,
                    label: Configuration.expand(path).deletingLastPathComponent().lastPathComponent,
                    token: "")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: Configuration.expand(path).path)
            let modified = attributes[.modificationDate] as? Date ?? .distantPast
            if accounts[account.id] == nil { order.append(account.id) }
            if modified > (accounts[account.id]?.1 ?? .distantPast) { accounts[account.id] = (account, modified) }
        }
        guard !order.isEmpty else { throw UsageError.message("No Codex accounts found.") }
        return order.compactMap { accounts[$0]?.0 }
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
