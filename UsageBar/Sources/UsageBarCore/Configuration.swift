import Foundation

public struct Configuration: Codable, Sendable {
    public var codexAuthFile = "~/.codex/auth.json"
    public var openRouterAuthFile = "~/.local/share/opencode/auth.json"
    public var nousURL = "http://nous:8080"
    public var nousSSHHost = "nous"
    public var hostUtilization = true

    public init() {}

    public static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/usage-bar/config.json")
    }

    public static func load() throws -> Configuration {
        guard FileManager.default.fileExists(atPath: self.file.path) else { return Configuration() }
        let value = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: self.file))
        try value.validate()
        return value
    }

    public func validate() throws {
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
