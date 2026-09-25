import CryptoKit
import Foundation

public enum DoctorState: String, Codable, Sendable { case passed, warning, failed, unsupported }
public enum HostRepair: String, Codable, Sendable, CaseIterable { case collector, service, linger, serve }

public struct DoctorCheck: Identifiable, Codable, Sendable {
    public let id: String
    public let requirement: String
    public let state: DoctorState
    public let detail: String
    public let repair: HostRepair?
    /// Stable remote facts, never sample counters, participate in consent invalidation.
    let evidence: String
}

public struct CommandStep: Sendable {
    public let title: String
    public let executable: URL
    public let arguments: [String]
    public let script: String?
    public let mutation: Bool
    public var displayScript: String {
        ([self.executable.path] + self.arguments).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
            + (self.script.map { "\n\nStandard input:\n" + $0 } ?? "")
    }
}

public struct SetupPlan: Sendable {
    public let host: InferenceHost
    public let observedStateDigest: String
    public let steps: [CommandStep]
    public let rollbackSteps: [CommandStep]
    public let selectedRepairs: Set<HostRepair>
    public let disclosure: String
    let artifactDigest: String
}

public enum SetupEvent: Sendable {
    case started(Int, String)
    case completed(Int, String)
    case rollback(String)
    case verified([DoctorCheck])
}

public actor HostDoctor {
    let artifacts: URL
    let ssh: URL
    let scp: URL
    let http: @Sendable (URL) async throws -> Data

    public init(
        artifacts: URL? = nil,
        ssh: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        scp: URL = URL(fileURLWithPath: "/usr/bin/scp"),
        http: (@Sendable (URL) async throws -> Data)? = nil)
    {
        self.artifacts = artifacts ?? (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("host")
        self.ssh = ssh
        self.scp = scp
        self.http = http ?? SetupProcess.fetch
    }

    static let options = [
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        "ForwardAgent=no",
        "-o",
        "ConnectTimeout=5",
        "-o",
        "NumberOfPasswordPrompts=0",
        "-o",
        "PasswordAuthentication=no",
        "-o",
        "KbdInteractiveAuthentication=no",
        "-o",
        "UseKeychain=no",
        "-o",
        "AddKeysToAgent=no",
    ]

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func hashes() throws -> [String] {
        try ["metrics.py", "pace-bar-metrics.service"].map {
            try Self.hash(Data(contentsOf: self.artifacts.appendingPathComponent($0)))
        }
    }

    func command(_ host: InferenceHost, title: String, script: String, mutation: Bool = true) -> CommandStep {
        CommandStep(
            title: title,
            executable: self.ssh,
            arguments: ["-T"] + Self.options + [host.sshHost ?? "", "sh -s"],
            script: script,
            mutation: mutation)
    }

    private func inspectFacts(_ host: InferenceHost) async throws -> [String: String] {
        try host.validate()
        guard host.sshHost != nil
        else { throw UsageError.message("Configure an SSH alias with an existing authorized key.") }
        let output = try await SetupProcess.run(self.command(
            host, title: "Inspect host",
            script: HostSetupScripts.inspect(port: Self.serverPort(host)), mutation: false))
        return try JSONDecoder().decode([String: String].self, from: Data(output.utf8))
    }

    /// Read-only diagnosis after a failed poll; never changes an inference service.
    public func diagnoseInferenceFailure(_ host: InferenceHost) async -> String {
        let facts = try? await self.inspectFacts(host)
        return Self.inferenceFailure(host, facts: facts)
    }

    public func inspect(_ host: InferenceHost) async -> [DoctorCheck] {
        var checks: [DoctorCheck] = []
        var remoteFacts: [String: String]?
        func add(
            _ id: String,
            _ requirement: String,
            _ passed: Bool,
            _ detail: String,
            repair: HostRepair? = nil,
            evidence: String = "",
            failure: DoctorState = .failed)
        {
            checks.append(DoctorCheck(
                id: id,
                requirement: requirement,
                state: passed ? .passed : failure,
                detail: detail,
                repair: passed ? nil : repair,
                evidence: evidence))
        }
        do {
            let facts = try await self.inspectFacts(host)
            remoteFacts = facts
            add(
                "ssh",
                "Non-interactive SSH",
                true,
                "Existing SSH alias/config used; no password or host-key prompts.",
                evidence: facts["identity"] ?? "")
            let supported = facts["linux"] == "yes" && facts["python"] == "yes" && facts["systemd"] == "yes"
            add(
                "platform",
                "Linux, /usr/bin/python3 and user systemd",
                supported,
                supported ? "Collector prerequisites available." :
                    "Install missing OS prerequisites through an authorized administrator.",
                evidence: ["linux", "python", "systemd"].map { facts[$0] ?? "missing" }.joined(separator: ":"),
                failure: .unsupported)
            let hashes = try self.hashes()
            let current = facts["script"] == hashes[0] && facts["unit"] == hashes[1]
            add(
                "collector",
                "Bundled collector and unit SHA-256",
                current,
                current ? "Installed files match this app." :
                    "Install or explicitly adopt/update the existing collector files.",
                repair: supported && facts["safe"] == "yes" ? .collector : nil,
                evidence: ["script", "unit", "safe"].map { facts[$0] ?? "missing" }.joined(separator: ":"))
            let service = facts["enabled"] == "enabled" && facts["active"] == "active" && facts["expectedProcess"] == "yes"
            add(
                "service",
                "Enabled service running the expected collector",
                service,
                service ? "Expected collector process is enabled and active." :
                    "Enable and start/restart only the metrics collector.",
                repair: supported && (current || facts["safe"] == "yes") ? .service : nil,
                evidence: ["enabled", "active", "exec", "pid", "expectedProcess"].map { facts[$0] ?? "missing" }
                    .joined(separator: ":"))
            add(
                "linger",
                "Service survives logout",
                facts["linger"] == "yes",
                "Linger: \(facts["linger"] ?? "unavailable"). Authorization may require an administrator.",
                repair: supported ? .linger : nil,
                evidence: facts["linger"] ?? "",
                failure: .warning)
            let snapshot = facts["snapshot"] ?? ""
            add(
                "loopback",
                "Host loopback /snapshot",
                (try? UsageParser.host(snapshot)) != nil,
                (try? UsageParser.host(snapshot)) != nil ? "Local snapshot parses." :
                    "Local collector snapshot unavailable.")
            let mapping = facts["serve"] ?? "unavailable"
            add(
                "serve",
                "Private Tailscale TCP 8082 mapping",
                mapping == "correct",
                "Port 8082: \(mapping). Other ports are preserved; no Funnel or public listener is enabled.",
                repair: supported && mapping == "unmapped" ? .serve : nil,
                evidence: mapping,
                failure: mapping == "conflict" ? .unsupported : .failed)
        } catch {
            add(
                "inspection",
                "Read-only remote inspection",
                false,
                "\(error.localizedDescription) No bootstrap is attempted; verify keys and trusted host identity independently.")
        }
        do {
            try host.validate()
            let data = try await self.http(URL(string: host.serverURL)!.appendingPathComponent("v1/models"))
            let model = try UsageParser.loadedModel(data)
            if let model {
                var parts = URLComponents(
                    url: URL(string: host.serverURL)!.appendingPathComponent("metrics"),
                    resolvingAgainstBaseURL: false)!
                parts.queryItems = [URLQueryItem(name: "model", value: model)]
                _ = try await UsageParser.nous(self.http(parts.url!), model: model)
            }
            add(
                "inference",
                "Inference API from this Mac",
                true,
                "Model inventory and applicable metrics reachable; an idle host is valid.")
        } catch let UsageError.unavailable(_, reason) {
            add("inference", "Inference API from this Mac", true, "Paused: \(reason ?? "temporarily unavailable.")")
        } catch { add(
            "inference",
            "Inference API from this Mac",
            false,
            Self.inferenceFailure(host, facts: remoteFacts)) }
        if let origin = host.metricsURL, !origin.isEmpty, let url = URL(string: origin) {
            do {
                let data = try await self.http(url.appendingPathComponent("snapshot"))
                guard data.count <= 16384,
                      let text = String(data: data, encoding: .utf8) else { throw UsageError.oversized }
                _ = try UsageParser.host(text)
                add("metrics", "Metrics origin from this Mac", true, "Configured /snapshot parses with the app parser.")
            } catch { add(
                "metrics",
                "Metrics origin from this Mac",
                false,
                "Configured /snapshot is unreachable or invalid.") }
        } else {
            add(
                "metrics",
                "Metrics origin from this Mac",
                false,
                "No metrics origin configured; SSH sampling remains explicit.",
                failure: .warning)
        }
        return checks
    }

    static func digest(_ checks: [DoctorCheck]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try Self.hash(encoder.encode(checks))
    }

    public func plan(
        _ host: InferenceHost,
        checks: [DoctorCheck],
        selectedRepairs: Set<HostRepair> = Set(HostRepair.allCases)) throws -> SetupPlan
    {
        try host.validate()
        let selected = Set(checks.filter { $0.state != .passed }.compactMap(\.repair)).intersection(selectedRepairs)
        let hashes = try self.hashes()
        var steps: [CommandStep] = []
        var rollback: [CommandStep] = []
        if !selected.isEmpty {
            guard checks.contains(where: { $0.id == "ssh" && $0.state == .passed }),
                  checks.contains(where: { $0.id == "platform" && $0.state == .passed })
            else {
                throw UsageError.message("Resolve SSH and platform prerequisites first.")
            }
        }
        if selected.contains(.collector) {
            let transaction = UUID().uuidString.lowercased()
            steps.append(self.command(
                host,
                title: "Create private staging directory",
                script: HostSetupScripts.stage(transaction)))
            for file in ["metrics.py", "pace-bar-metrics.service"] {
                steps.append(CommandStep(
                    title: "Stage \(file)",
                    executable: self.scp,
                    arguments: Self.options + [
                        self.artifacts.appendingPathComponent(file).path,
                        "\(host.sshHost!):.local/share/pace-bar/setup/\(transaction)/\(file)",
                    ],
                    script: nil,
                    mutation: true))
            }
            steps.append(self.command(
                host,
                title: "Adopt/update collector (prior files and service state backed up)",
                script: HostSetupScripts.install(transaction, hashes: hashes)))
            rollback.append(self.command(
                host,
                title: "Guarded collector rollback",
                script: HostSetupScripts.rollback(transaction, hashes: hashes)))
        } else if selected.contains(.service) {
            guard checks.contains(where: { $0.id == "collector" && $0.state == .passed }) else {
                throw UsageError.message("Select collector installation before starting a mismatched service.")
            }
            steps.append(self.command(
                host,
                title: "Enable and restart metrics service",
                script: "set -eu\nsystemctl --user enable pace-bar-metrics.service\nsystemctl --user restart pace-bar-metrics.service\n"))
        }
        if selected.contains(.linger) {
            steps.append(self.command(
                host,
                title: "Enable linger (retained on rollback)",
                script: "set -eu\nloginctl --no-ask-password enable-linger \"$(id -un)\"\n"))
        }
        if selected.contains(.serve) {
            let transaction = UUID().uuidString.lowercased()
            steps.append(self.command(
                host,
                title: "Expose only private TCP 8082",
                script: HostSetupScripts.serve(transaction)))
            rollback.insert(self.command(
                host,
                title: "Remove only this transaction's unchanged mapping",
                script: HostSetupScripts.undoServe(transaction)), at: 0)
        }
        return try SetupPlan(
            host: host,
            observedStateDigest: Self.digest(checks),
            steps: steps,
            rollbackSteps: rollback,
            selectedRepairs: selected,
            disclosure: "Uses your SSH alias and config, including any ProxyCommand or Match exec. Updates only Pace Bar's "
                + "files and metrics service, never inference or energy checkpoints. An existing installation is adopted "
                +
                "explicitly. Linger is kept. After a disconnect or cancel, the remote outcome may be unknown; check again.",
            artifactDigest: hashes.joined())
    }

    public nonisolated func run(_ plan: SetupPlan) -> AsyncThrowingStream<SetupEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.execute(plan, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func execute(
        _ plan: SetupPlan,
        continuation: AsyncThrowingStream<SetupEvent, Error>.Continuation) async throws
    {
        guard try self.hashes().joined() == plan.artifactDigest,
              try await Self.digest(self.inspect(plan.host)) == plan.observedStateDigest
        else {
            throw UsageError.message("Host or bundled files changed. Inspect and approve a new plan.")
        }
        guard !plan.steps.isEmpty else { await continuation.yield(.verified(self.inspect(plan.host))); return }
        do {
            for (index, step) in plan.steps.enumerated() {
                try Task.checkCancellation()
                continuation.yield(.started(index, step.title))
                let output = try await SetupProcess.run(step)
                continuation.yield(.completed(index, output))
            }
            let checks = await self.inspect(plan.host)
            var required = Set(plan.selectedRepairs.map(\.rawValue))
            if plan.selectedRepairs.contains(.collector) || plan.selectedRepairs.contains(.service) || plan
                .selectedRepairs.contains(.serve)
            {
                required.formUnion(["collector", "service", "loopback"])
                if let origin = plan.host.metricsURL, !origin.isEmpty { required.insert("metrics") }
            }
            guard required.allSatisfy({ id in checks.contains { $0.id == id && $0.state == .passed } }) else {
                throw UsageError.message("Setup verification failed.")
            }
            continuation.yield(.verified(checks))
        } catch {
            if Task.isCancelled {
                throw UsageError
                    .message("Cancelled; remote outcome may be unknown. Reconnect and inspect before further changes.")
            }
            for step in plan.rollbackSteps {
                do {
                    try await continuation.yield(.rollback(SetupProcess.run(step)))
                } catch {
                    throw UsageError.message(
                        "Setup failed and the guarded rollback could not finish. Check again before changing anything.")
                }
            }
            throw error
        }
    }
}
