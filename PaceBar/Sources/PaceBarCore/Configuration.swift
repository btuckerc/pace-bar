import Foundation

/// How the status item draws quota. Both are template images tinted by the menu bar.
public enum MenuBarIcon: String, Codable, CaseIterable, Sendable {
    /// Codex 1–4 as level bars, then a separated Claude bar.
    case bars
    /// Codex 1–4 as four separated arcs, matching the app icon.
    case orbit
}

public struct Configuration: Codable, Sendable {
    public var codexAuthFile = "~/.codex/auth.json"
    public var openRouterAuthFile = "~/.local/share/opencode/auth.json"
    public var nousURL = "http://nous:8080"
    public var nousSSHHost = "nous"
    public var hostUtilization = true
    public var electricityUSDPerKWh: Double?
    public var nousMetricsURL: String?
    public var menuBarIcon = MenuBarIcon.bars

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.codexAuthFile = try container.decode(String.self, forKey: .codexAuthFile)
        self.openRouterAuthFile = try container.decode(String.self, forKey: .openRouterAuthFile)
        self.nousURL = try container.decode(String.self, forKey: .nousURL)
        self.nousSSHHost = try container.decode(String.self, forKey: .nousSSHHost)
        self.hostUtilization = try container.decode(Bool.self, forKey: .hostUtilization)
        self.electricityUSDPerKWh = try container.decodeIfPresent(Double.self, forKey: .electricityUSDPerKWh)
        self.nousMetricsURL = try container.decodeIfPresent(String.self, forKey: .nousMetricsURL)
        // Settings files written before the icon choice existed keep loading with the default.
        self.menuBarIcon = try container.decodeIfPresent(MenuBarIcon.self, forKey: .menuBarIcon) ?? .bars
    }

    public static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/pace-bar/config.json")
    }

    public static func load() throws -> Configuration {
        guard FileManager.default.fileExists(atPath: self.file.path) else { return Configuration() }
        let value = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: self.file))
        try value.validate()
        return value
    }

    public func validate() throws {
        if let rate = self.electricityUSDPerKWh, !rate.isFinite || rate < 0 {
            throw UsageError.message("Electricity rate must be a nonnegative USD/kWh amount.")
        }
        if let origin = self.nousMetricsURL, !origin.isEmpty {
            guard let url = URL(string: origin), ["http", "https"].contains(url.scheme),
                  url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.isEmpty || url.path == "/"
            else { throw UsageError.message("Metrics URL must be an HTTP(S) server origin.") }
        }
        guard let url = URL(string: self.nousURL), ["http", "https"].contains(url.scheme),
              url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/"
        else { throw UsageError.message("Nous URL must be an HTTP(S) server origin.") }
        guard !self.nousSSHHost.isEmpty, !self.nousSSHHost.hasPrefix("-"),
              self.nousSSHHost.range(of: "^[A-Za-z0-9_.@-]+$", options: .regularExpression) != nil
        else { throw UsageError.message("Invalid SSH host.") }
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

    public func createIfMissing() throws {
        let file = Self.file
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: file, options: .atomic)
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
