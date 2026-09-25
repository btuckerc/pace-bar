import Darwin
import Foundation
import Observation

private final class InspectionOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var overflow = false

    func append(_ chunk: Data) {
        self.lock.lock()
        defer { self.lock.unlock() }
        if self.data.count + chunk.count > 65536 { self.overflow = true }
        self.data.append(chunk.prefix(max(0, 65536 - self.data.count)))
    }

    func result() throws -> Data {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard !self.overflow else { throw UsageError.message("Executable inspection output too large.") }
        return self.data
    }
}

private func stopLoginProcess(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    Task {
        try? await Task.sleep(for: .milliseconds(300))
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}

private func drainLoginOutput(_ handle: FileHandle) -> Data {
    let descriptor = handle.fileDescriptor
    _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while result.count < 65536 {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        guard count > 0 else { break }
        result.append(contentsOf: buffer.prefix(count))
    }
    return result
}

public struct LoginTool: Sendable {
    public let executable: URL
    public let version: String

    public static func locate(
        _ name: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL
    {
        for directory in [
            home.appendingPathComponent(".local/share/mise/shims").path,
            home.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ] {
            let path = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path.path) { return path }
        }
        throw UsageError
            .message(
                "\(name) is not installed in the supported executable locations. Install it separately, then retry.")
    }

    public static func inspect(_ name: String) async throws -> LoginTool {
        let executable = try self.locate(name)
        let version = try await self.output(executable, arguments: ["--version"])
        return LoginTool(executable: executable, version: version.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = "\(home)/.local/share/mise/shims:\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        environment["NO_COLOR"] = "1"
        return environment
    }

    public static func output(_ executable: URL, arguments: [String]) async throws -> String {
        try await Task.detached {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = self.environment
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe
            process.standardError = pipe
            let captured = InspectionOutput()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                captured.append(handle.availableData)
            }
            defer { pipe.fileHandleForReading.readabilityHandler = nil }
            try process.run()
            let deadline = Date().addingTimeInterval(10)
            while process.isRunning, Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            if process.isRunning {
                stopLoginProcess(process)
                throw UsageError.message("Executable inspection timed out.")
            }
            pipe.fileHandleForReading.readabilityHandler = nil
            captured.append(drainLoginOutput(pipe.fileHandleForReading))
            let data = try captured.result()
            guard process.terminationStatus == 0, data.count <= 65536 else {
                throw UsageError.message("Executable inspection failed.")
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw UsageError.message("Executable returned invalid text.")
            }
            return text
        }.value
    }

    /// Supported read-only OMP config commands. Never bypass a broker or resolve a !command ourselves.
    public static func localOMPDatabase(_ executable: URL) async throws -> URL {
        if let broker = self.environment["OMP_AUTH_BROKER_URL"], !broker.isEmpty {
            throw UsageError
                .message(
                    "OMP uses an auth broker. Local Claude enrollment is unavailable; Pace Bar will not alter broker settings.")
        }
        let config = try await self.output(executable, arguments: ["config", "get", "auth.broker.url", "--json"])
        guard let data = config.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["key"] as? String == "auth.broker.url"
        else {
            throw UsageError.message("Cannot determine OMP's credential destination.")
        }
        if let value = object["value"], !(value is NSNull), (value as? String)?.isEmpty != true {
            throw UsageError
                .message("OMP has a broker configured. Local Claude enrollment cannot observe broker sign-ins.")
        }
        let directory = try await self.output(executable, arguments: ["config", "path"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard directory.hasPrefix("/"),
              !directory.contains("\n") else { throw UsageError.message("OMP credential directory unavailable.") }
        return URL(fileURLWithPath: directory).appendingPathComponent("agent.db")
    }
}

public struct AccountLoginPlan: Sendable {
    public let provider: AccountProvider
    public let executable: URL
    public let home: URL?
    public let database: URL?
    public let logout: Bool
    public let expectedIdentity: String?

    public init(
        provider: AccountProvider,
        executable: URL,
        home: URL? = nil,
        database: URL? = nil,
        logout: Bool = false,
        expectedIdentity: String? = nil)
    {
        self.provider = provider
        self.executable = executable
        self.home = home
        self.database = database
        self.logout = logout
        self.expectedIdentity = expectedIdentity
    }

    public var arguments: [String] {
        self.provider == .codex ? ["-c", "cli_auth_credentials_store=\"file\"", self.logout ? "logout" : "login"] : [
            "login",
            "anthropic",
        ]
    }

    public var command: String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return (self.home.map { "CODEX_HOME=\(quote($0.path)) " } ?? "")
            + ([self.executable.path] + self.arguments).map(quote).joined(separator: " ")
    }
}

/// Transient, consent-started CLI session. Tokens, raw output and stdin are never persisted.
@MainActor @Observable
public final class AccountSignIn {
    public private(set) var running = false
    public private(set) var cancelled = false
    public private(set) var progress = ""
    public private(set) var candidates: [AccountCandidate] = []
    public private(set) var error: String?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: Pipe?
    @ObservationIgnored private var output: Pipe?
    @ObservationIgnored private var pendingOutput = ""
    @ObservationIgnored private var plan: AccountLoginPlan?
    @ObservationIgnored private var before: [AccountCandidate] = []
    @ObservationIgnored private var workingDirectory: URL?

    public init() {}

    public func start(_ plan: AccountLoginPlan) throws {
        guard !self.running else { return }
        self.cancelled = false
        self.error = nil
        self.candidates = []
        self.progress = ""
        self.pendingOutput = ""
        self.plan = plan
        if plan.provider == .claude {
            guard let database = plan.database
            else { throw UsageError.message("OMP local destination has not been verified.") }
            self.before = try ClaudeAccount.candidates(database: database)
        }
        let fm = FileManager.default
        if plan.provider == .codex {
            guard let home = plan.home else { throw UsageError.message("A private Codex home is required.") }
            if !plan.logout {
                guard !fm.fileExists(atPath: home.path)
                else { throw UsageError.message("The new Codex home already exists; choose a fresh sign-in.") }
                try fm.createDirectory(
                    at: home,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
            } else {
                try AccountDiscovery.validateLogout(home: home, expectedIdentity: plan.expectedIdentity)
            }
        }
        let cwd = fm.temporaryDirectory.appendingPathComponent("pace-sign-in-\(UUID().uuidString)")
        try fm.createDirectory(at: cwd, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        self.workingDirectory = cwd
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = plan.executable
        process.arguments = plan.arguments
        var environment = LoginTool.environment
        if let home = plan.home { environment["CODEX_HOME"] = home.path }
        process.environment = environment
        process.currentDirectoryURL = cwd
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.append(data) }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor in self?.finished(status: status) }
        }
        self.process = process
        self.input = input
        self.output = output
        do {
            if plan.logout, let home = plan.home {
                try AccountDiscovery.validateLogout(home: home, expectedIdentity: plan.expectedIdentity)
            }
            try process.run()
            self.running = true
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            try? fm.removeItem(at: cwd)
            self.process = nil
            throw UsageError.message("Could not launch the selected executable.")
        }
    }

    public func send(_ answer: String) {
        guard self.running else { return }
        try? self.input?.fileHandleForWriting.write(contentsOf: Data((answer + "\n").utf8))
    }

    public func cancel() {
        self.cancelled = true
        self.candidates = []
        if let process = self.process { stopLoginProcess(process) }
        self.progress += "\nCancelled. The CLI may have saved credentials. Resume enrollment to inspect them, "
            + "or separately sign out of this private home.\n"
    }

    public func resume() throws {
        guard !self.running, let plan = self.plan, plan.provider == .codex, !plan.logout else { return }
        self.candidates = try self.codexCandidates(plan)
        self.cancelled = false
    }

    private func append(_ data: Data) {
        // Re-sanitize the entire transient window, including incomplete prompts.
        self.pendingOutput += String(data: data, encoding: .utf8) ?? "[invalid CLI text]"
        self.pendingOutput = String(self.pendingOutput.suffix(16384))
        let display = self.pendingOutput.replacingOccurrences(
            of: "[A-Za-z0-9_+/=-]+$", with: "", options: .regularExpression)
        self.progress = Self.sanitize(display)
        self.progress = String(self.progress.suffix(16384))
    }

    private static func sanitize(_ line: String) -> String {
        line.replacingOccurrences(of: "\\u{001B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "https?://[^\\s]+", with: "[browser link hidden]", options: .regularExpression)
            .replacingOccurrences(
                of: "[A-Za-z0-9_+/=-]{16,}",
                with: "[sensitive value hidden]",
                options: .regularExpression)
            .replacingOccurrences(
                of: "\\b[A-Z0-9]{4}-[A-Z0-9]{4}\\b",
                with: "[code hidden]",
                options: .regularExpression)
    }

    private func codexCandidates(_ plan: AccountLoginPlan) throws -> [AccountCandidate] {
        guard let home = plan.home else { return [] }
        let path = home.appendingPathComponent("auth.json").path
        let account = try CodexAccount.parse(Configuration.boundedRead(path))
        return [AccountCandidate(
            provider: .codex,
            providerAccountID: account.id,
            label: "Codex",
            source: .codexFiles(paths: [path], managedHome: home.path),
            identityHint: account.identityHint)]
    }

    private func finished(status: Int32) {
        self.output?.fileHandleForReading.readabilityHandler = nil
        if let handle = self.output?.fileHandleForReading { self.append(drainLoginOutput(handle)) }
        self.running = false
        self.process = nil
        self.input = nil
        self.output = nil
        if let directory = self.workingDirectory { try? FileManager.default.removeItem(at: directory) }
        guard !self.cancelled, let plan = self.plan else { return }
        guard status == 0 else { self.error = "Sign-in command failed. No account was enrolled."; return }
        guard !plan.logout else { self.progress += "\nSigned out of the selected local home."; return }
        do {
            if plan.provider == .codex {
                self.candidates = try self.codexCandidates(plan)
            } else if let database = plan.database {
                let after = try ClaudeAccount.candidates(database: database)
                self.candidates = after.filter { candidate in
                    candidate.issue == nil && !self.before
                        .contains {
                            $0.providerAccountID == candidate.providerAccountID && $0.source == candidate.source
                        }
                }
            }
            if self.candidates
                .isEmpty
            {
                self
                    .error =
                    "No new readable local identity was found. Nothing has been enrolled; existing accounts are unchanged."
            }
        } catch { self.error = "The CLI finished without a readable account identity. Nothing has been enrolled." }
    }
}
