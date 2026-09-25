import Foundation
import Testing
@testable import PaceBarCore

struct HostDoctorTests {
    private struct Fixture {
        let root: URL
        let doctor: HostDoctor
        let host = InferenceHost(metricsURL: "http://fixture:8082")
        let facts: URL
        let log: URL
    }

    private func fixture(passing: Bool = true, apiAvailable: Bool = true) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        for name in ["metrics.py", "pace-bar-metrics.service"] {
            try Data(name.utf8).write(to: root.appendingPathComponent(name))
        }
        let facts = root.appendingPathComponent("facts.json")
        let values = [
            "linux": "yes",
            "python": "yes",
            "systemd": "yes",
            "identity": "fixture",
            "script": passing ? HostDoctor.hash(Data("metrics.py".utf8)) : "missing",
            "unit": passing ? HostDoctor.hash(Data("pace-bar-metrics.service".utf8)) : "missing",
            "safe": "yes",
            "enabled": "enabled",
            "active": "active",
            "pid": "123",
            "exec": "expected",
            "expectedProcess": "yes",
            "linger": "yes",
            "snapshot": "Mem: 100 20",
            "serve": "correct",
        ]
        try JSONEncoder().encode(values).write(to: facts)
        let log = root.appendingPathComponent("argv")
        let ssh = root.appendingPathComponent("ssh")
        try Data("""
        #!/bin/sh
        printf '%s\\n' "$@" >> '\(log.path)'
        printf '%s\\n' "$SSH_ASKPASS_REQUIRE" >> '\(log.path)'
        /bin/cat > '\(root.path)/stdin'
        /bin/cat '\(facts.path)'
        """.utf8).write(to: ssh)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
        let doctor = HostDoctor(artifacts: root, ssh: ssh, scp: ssh, http: { url in
            guard apiAvailable else { throw URLError(.cannotConnectToHost) }
            return Data((url.path == "/v1/models" ? "{\"data\":[]}" : "Mem: 100 20").utf8)
        })
        return Fixture(root: root, doctor: doctor, facts: facts, log: log)
    }

    @Test func `Passing host produces no mutation and strict SSH never prompts`() async throws {
        let f = try self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let checks = await f.doctor.inspect(f.host)
        #expect(checks.allSatisfy { $0.state == .passed })
        let plan = try await f.doctor.plan(f.host, checks: checks)
        #expect(plan.steps.isEmpty)
        for try await event in f.doctor.run(plan) {
            if case .started = event { Issue.record("No-op started a command") }
        }
        let argv = try String(contentsOf: f.log, encoding: .utf8)
        for value in ["BatchMode=yes", "UseKeychain=no", "AddKeysToAgent=no", "StrictHostKeyChecking=yes", "never"] {
            #expect(argv.contains(value))
        }
    }

    @Test func `Planning does not mutate and changed consent is refused before any step`() async throws {
        let f = try self.fixture(passing: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let checks = await f.doctor.inspect(f.host)
        let before = try Data(contentsOf: f.log)
        let plan = try await f.doctor.plan(f.host, checks: checks, selectedRepairs: [.collector])
        #expect(plan.steps.count == 4)
        #expect(try Data(contentsOf: f.log) == before)
        var facts = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: f.facts))
        facts["pid"] = "456"
        try JSONEncoder().encode(facts).write(to: f.facts)
        var refused = false
        do {
            for try await event in f.doctor.run(plan) {
                if case .started = event { Issue.record("Stale plan mutated") }
            }
        } catch { refused = true }
        #expect(refused)
    }

    @Test func `Authentication failure has no available repair`() async throws {
        let f = try self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try Data("#!/bin/sh\nexit 255\n".utf8).write(to: f.root.appendingPathComponent("ssh"))
        let checks = await f.doctor.inspect(f.host)
        #expect(checks.contains { $0.id == "inspection" && $0.state == .failed })
        #expect(checks.allSatisfy { $0.repair == nil })
    }

    @Test(arguments: ["no", "yes", "unknown"])
    func `Failed API is classified using the remote listener without offering inference repair`(
        _ listener: String) async throws
    {
        let f = try self.fixture(apiAvailable: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        var facts = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: f.facts))
        facts["inferenceListener"] = listener
        try JSONEncoder().encode(facts).write(to: f.facts)
        let checks = await f.doctor.inspect(f.host)
        let inference = try #require(checks.first { $0.id == "inference" })
        #expect(inference.state == .failed)
        #expect(inference.repair == nil)
        if listener == "no" {
            #expect(inference.detail.contains("Nothing is listening on port 8080"))
        } else {
            #expect(inference.detail.contains("is reachable"))
            #expect(!inference.detail.contains("Nothing is listening"))
        }
    }

    @Test func `Failed SSH and API do not claim the server has stopped`() async throws {
        let f = try self.fixture(apiAvailable: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        try Data("#!/bin/sh\nexit 255\n".utf8).write(to: f.root.appendingPathComponent("ssh"))
        let checks = await f.doctor.inspect(f.host)
        let inference = try #require(checks.first { $0.id == "inference" })
        #expect(inference.state == .failed)
        #expect(inference.detail.contains("cannot be reached or inspected"))
        #expect(inference.repair == nil)
    }

    @Test func `A failed inference poll clears live activity while preserving accumulated history`() throws {
        var reading = HostReading()
        reading.nous = try UsageParser.nous(Data("""
        llamacpp:tokens_predicted_total 123
        llamacpp:prompt_tokens_total 100
        llamacpp:prompt_tokens_cached_total 20
        llamacpp:predicted_tokens_seconds 42
        llamacpp:requests_processing 1
        """.utf8), model: "Example-9B")
        reading.lifetime = NousLifetimeTotals(promptTokens: 100, cachedTokens: 20, outputTokens: 123)
        try reading.energy.record(UsageParser.host("GPU 12, 6246, 10240, 27.2\nENERGY 1000 1000"))
        try reading.energy.record(UsageParser.host("GPU 12, 6246, 10240, 27.2\nENERGY 360001000 4600"))
        let energy = reading.energy.wattHours
        #expect(reading.nous?.generationTPS == 42)
        reading.inferenceFailed()
        #expect(reading.nous == nil)
        #expect(reading.lifetime?.outputTokens == 123)
        #expect(reading.lifetime?.promptTokens == 100)
        #expect(reading.lifetime?.cachedTokens == 20)
        #expect(reading.energy.wattHours == energy)
        reading.nous = .idle
        #expect(reading.nous != nil)
        #expect(reading.nous?.generationTPS == nil)
    }

    @Test func `Failed install restores prior files and prior service state`() async throws {
        let f = try self.fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let home = f.root.appendingPathComponent("home")
        let bin = f.root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let systemctl = bin.appendingPathComponent("systemctl")
        try Data("""
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(f.root.path)/service-log'
        case "$*" in *restart*) exit 1;; esac
        exit 0
        """.utf8).write(to: systemctl)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: systemctl.path)
        let fakeSSH = f.root.appendingPathComponent("remote")
        try Data("""
        #!/bin/sh
        export HOME='\(home.path)'
        export PATH='\(bin.path)':/usr/bin:/bin
        exec /bin/sh -s
        """.utf8).write(to: fakeSSH)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)
        let id = UUID().uuidString.lowercased()
        let stage = home.appendingPathComponent(".local/share/pace-bar/setup/\(id)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let paths = [".local/lib/pace-bar/metrics.py", ".config/systemd/user/pace-bar-metrics.service"]
        for (index, name) in ["metrics.py", "pace-bar-metrics.service"].enumerated() {
            try Data(name.utf8).write(to: stage.appendingPathComponent(name))
            let destination = home.appendingPathComponent(paths[index])
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data("prior-\(index)".utf8).write(to: destination)
        }
        let hashes = try await f.doctor.hashes()
        let install = CommandStep(
            title: "Install",
            executable: fakeSSH,
            arguments: HostDoctor.options,
            script: HostSetupScripts.install(id, hashes: hashes),
            mutation: true)
        await #expect(throws: (any Error).self) { try await SetupProcess.run(install) }
        let rollback = CommandStep(
            title: "Restore",
            executable: fakeSSH,
            arguments: HostDoctor.options,
            script: HostSetupScripts.rollback(id, hashes: hashes),
            mutation: true)
        _ = try await SetupProcess.run(rollback)
        for (index, path) in paths.enumerated() {
            #expect(try String(contentsOf: home.appendingPathComponent(path), encoding: .utf8) == "prior-\(index)")
        }
        let log = try String(contentsOf: f.root.appendingPathComponent("service-log"), encoding: .utf8)
        #expect(log.contains("--user disable --now pace-bar-metrics.service"))
        #expect(log.contains("--user start pace-bar-metrics.service"))
    }
}
