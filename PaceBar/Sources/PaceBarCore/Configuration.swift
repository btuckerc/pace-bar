import Foundation

/// How the status item draws quota. Both are template images tinted by the menu bar.
public enum MenuBarIcon: String, Codable, CaseIterable, Sendable {
    /// One bar per active account, grouped by provider.
    case bars
    /// One glyph per provider, split into account arcs.
    case orbit
}

public struct Configuration: Codable, Sendable {
    public var schemaVersion = 2
    public var accounts: [AccountEnrollment] = []
    public var nextAccountNumber: [String: Int] = ["codex": 1, "claude": 1]
    public var accountMigration: [String: AccountMigrationState] = ["codex": .complete, "claude": .complete]
    /// Pre-registry settings named one Codex auth file. It only seeds account migration and is dropped once that is
    /// complete; the cost estimate follows tracked accounts instead.
    public var legacyCodexAuthFile: String?
    public var openRouterAuthFile = "~/.local/share/opencode/auth.json"
    public var hosts: [InferenceHost] = []
    public var menuBarIcon = MenuBarIcon.bars

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.accounts = try container.decodeIfPresent([AccountEnrollment].self, forKey: .accounts) ?? []
        self.nextAccountNumber = try container.decodeIfPresent([String: Int].self, forKey: .nextAccountNumber) ?? [
            "codex": 1,
            "claude": 1,
        ]
        self.accountMigration = try container.decodeIfPresent(
            [String: AccountMigrationState].self,
            forKey: .accountMigration)
            ?? [
                "codex": self.schemaVersion < 2 ? .pending : .complete,
                "claude": self.schemaVersion < 2 ? .pending : .complete,
            ]
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        self.legacyCodexAuthFile = try container.decodeIfPresent(String.self, forKey: .legacyCodexAuthFile)
            ?? legacy.decodeIfPresent(String.self, forKey: .codexAuthFile)
        self.openRouterAuthFile = try container.decode(String.self, forKey: .openRouterAuthFile)
        self.hosts = try container.decodeIfPresent([InferenceHost].self, forKey: .hosts) ?? [
            InferenceHost(
                name: "nous",
                serverURL: legacy.decodeIfPresent(String.self, forKey: .nousURL) ?? "http://nous:8080",
                sshHost: legacy.decodeIfPresent(String.self, forKey: .nousSSHHost) ?? "nous",
                metricsURL: legacy.decodeIfPresent(String.self, forKey: .nousMetricsURL),
                hostUtilization: legacy.decodeIfPresent(Bool.self, forKey: .hostUtilization) ?? true,
                electricityUSDPerKWh: legacy.decodeIfPresent(Double.self, forKey: .electricityUSDPerKWh)),
        ]
        // Settings files written before the icon choice existed keep loading with the default.
        self.menuBarIcon = try container.decodeIfPresent(MenuBarIcon.self, forKey: .menuBarIcon) ?? .bars
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, accounts, nextAccountNumber, accountMigration, openRouterAuthFile, hosts, menuBarIcon
        case legacyCodexAuthFile = "codexCostAuthFile"
    }

    private enum LegacyKeys: String, CodingKey {
        case codexAuthFile, nousURL, nousSSHHost, nousMetricsURL, hostUtilization, electricityUSDPerKWh
    }

    /// Codex homes whose session logs feed the cost estimate, beyond `~/.codex`: every tracked Codex sign-in's folder.
    public var codexCostHomes: [URL] {
        let files = self.accounts.flatMap { entry -> [String] in
            guard case let .codexFiles(paths, _) = entry.source else { return [] }
            return paths
        } + (self.legacyCodexAuthFile.map { [$0] } ?? [])
        return files.map { Configuration.expand($0).deletingLastPathComponent() }
    }

    public static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/pace-bar/config.json")
    }

    public static func load(file: URL = Configuration.file, legacyEvidence: Bool? = nil) throws -> Configuration {
        let exists = FileManager.default.fileExists(atPath: file.path)
        let oldData = exists ? try Data(contentsOf: file) : nil
        var value = try oldData.map { try JSONDecoder().decode(Configuration.self, from: $0) } ?? Configuration()
        let historyExists = legacyEvidence ?? FileManager.default.fileExists(
            atPath: Configuration.expand("~/.local/share/pace-bar/quota-history.json").path)
        if !exists, historyExists {
            value.accountMigration = ["codex": .pending, "claude": .pending]
        }
        if value.accountMigration.values.contains(.pending) {
            let paths = try? AccountDiscovery.codexPaths(value)
            let codex = AccountDiscovery.codex(paths: paths ?? value.accounts.flatMap {
                if case let .codexFiles(paths, _) = $0.source { return paths }
                return []
            })
            let database = ClaudeAccount.ompDatabase
            let claude = try? ClaudeAccount.candidates(database: database)
            value.migrateAccounts(
                codex: codex,
                claude: claude ?? [],
                codexReadable: paths != nil,
                claudeReadable: claude != nil)
            if let oldData, value.schemaVersion == 2 {
                let backup = file.appendingPathExtension("pre-v2")
                if !FileManager.default.fileExists(atPath: backup.path) {
                    try oldData.write(to: backup, options: .withoutOverwriting)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                }
            }
            try value.save(file: file)
        }
        if value.accountMigration["codex"] == .complete { value.legacyCodexAuthFile = nil }
        try value.validate()
        if let oldData,
           let object = try JSONSerialization.jsonObject(with: oldData) as? [String: Any],
           object["hosts"] == nil || object["codexCostAuthFile"] != nil || object["codexAuthFile"] != nil
        { try value.save(file: file) }
        return value
    }

    public func validate() throws {
        guard self.schemaVersion == 2 || self.schemaVersion == 1
        else { throw UsageError.message("Unsupported settings version.") }
        guard Set(self.accounts.map(\.id)).count == self.accounts.count
        else { throw UsageError.message("Duplicate enrollment IDs.") }
        for provider in AccountProvider.allCases {
            let entries = self.accounts.filter { $0.provider == provider }
            let identities = entries.compactMap(\.providerAccountID)
            guard Set(identities).count == identities.count, Set(entries.map(\.slot)).count == entries.count,
                  entries
                      .allSatisfy({ !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.slot >= 0
                      }),
                      (self.nextAccountNumber[provider.rawValue] ?? 0) > (entries.map(\.slot).max() ?? -1) + 1
            else { throw UsageError.message("Invalid account registry.") }
            for entry in entries {
                switch entry.source {
                case let .codexFiles(paths, home):
                    guard provider == .codex, !paths.isEmpty, paths.allSatisfy({ !$0.isEmpty }),
                          home == nil || paths
                              .contains(Configuration.expand(home!).appendingPathComponent("auth.json").path)
                    else { throw UsageError.message("Invalid Codex source.") }
                case let .omp(database, _):
                    guard provider == .claude,
                          !database.isEmpty else { throw UsageError.message("Invalid Claude source.") }
                }
            }
        }
        for host in self.hosts {
            try host.validate()
        }
        guard Set(self.hosts.map(\.id)).count == self.hosts.count,
              Set(self.hosts.map(\.normalizedOrigin)).count == self.hosts.count
        else { throw UsageError.message("Duplicate host IDs or server origins.") }
    }

    public static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    public static func boundedRead(_ path: String) throws -> Data {
        let handle = try FileHandle(forReadingFrom: self.expand(path))
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw UsageError.oversized }
        return data
    }

    public func save(file: URL = Configuration.file) throws {
        try self.validate()
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public func createIfMissing() throws {
        guard !FileManager.default.fileExists(atPath: Self.file.path) else { return }
        try self.save()
    }
}

public enum Credentials {
    public static func codex(_ data: Data) throws -> (token: String, account: String?) {
        let root = try UsageParser.object(data)
        guard let tokens = root["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty
        else { throw UsageError.message("Sign in to Codex with your subscription first.") }
        return (access, tokens["account_id"] as? String)
    }

    public static func openRouter(_ data: Data) throws -> String {
        let root = try UsageParser.object(data)
        if let auth = root["openrouter"] as? [String: Any], auth["type"] as? String == "api",
           let key = auth["key"] as? String, !key.isEmpty { return key }
        if let key = root["apiKey"] as? String, !key.isEmpty { return key }
        throw UsageError.message("Set an OpenRouter credential file in Settings.")
    }
}
