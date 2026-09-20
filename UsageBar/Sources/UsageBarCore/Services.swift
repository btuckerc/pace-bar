import Darwin
import Foundation

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        completionHandler(nil)
    }
}

public actor Services {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    private func get(_ url: URL, headers: [String: String] = [:], limit: Int = 1_048_576) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("UsageBar/0.1", forHTTPHeaderField: "User-Agent")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (bytes, response) = try await self.session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw UsageError.message("Invalid HTTP response.")
        }
        guard response.statusCode == 200 else { throw UsageError.http(response.statusCode) }
        guard response.expectedContentLength <= limit else { throw UsageError.oversized }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw UsageError.oversized }
            data.append(byte)
        }
        return data
    }

    public func codex(_ configuration: Configuration) async throws -> CodexSnapshot {
        let auth = try CodexAccount.parse(Configuration.boundedRead(configuration.codexAuthFile))
        return try await self.codex(account: auth)
    }

    public func codex(account auth: CodexAccount) async throws -> CodexSnapshot {
        guard !auth.token.isEmpty
        else { throw UsageError.message("Account sign-in unreadable. Sign in through its Codex home.") }
        var headers = ["Authorization": "Bearer \(auth.token)", "Accept": "application/json"]
        headers["ChatGPT-Account-Id"] = auth.id
        do {
            let data = try await self.get(URL(string: "https://chatgpt.com/backend-api/wham/usage")!, headers: headers)
            let root = try UsageParser.object(data)
            if let responseID = root["account_id"] as? String, responseID != auth.id {
                throw UsageError.message("Account identity mismatch.")
            }
            return try UsageParser.codex(data)
        } catch UsageError.http(401) {
            throw UsageError.message("Codex login expired. Sign in through Codex, then refresh.")
        }
    }

    public func openRouter(_ configuration: Configuration) async throws -> OpenRouterSnapshot {
        let token = try Credentials.openRouter(Configuration.boundedRead(configuration.openRouterAuthFile))
        let headers = ["Authorization": "Bearer \(token)", "Accept": "application/json"]
        let credits = try await self.get(URL(string: "https://openrouter.ai/api/v1/credits")!, headers: headers)
        return try UsageParser.openRouter(key: nil, credits: credits, warning: nil)
    }

    public func nous(_ configuration: Configuration) async throws -> NousSnapshot {
        try configuration.validate()
        let origin = URL(string: configuration.nousURL)!
        let models = try await self.get(origin.appendingPathComponent("v1/models"))
        guard let model = try UsageParser.loadedModel(models) else { return .idle }
        var components = URLComponents(url: origin.appendingPathComponent("metrics"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        let data = try await self.get(components.url!, limit: 65536)
        return try UsageParser.nous(data, model: model)
    }

    public func host(_ configuration: Configuration) async throws -> HostSnapshot {
        try configuration.validate()
        if let origin = configuration.nousMetricsURL, !origin.isEmpty {
            let data = try await self.get(URL(string: origin)!.appendingPathComponent("snapshot"), limit: 16384)
            guard let text = String(data: data, encoding: .utf8)
            else { throw UsageError.message("Invalid host snapshot.") }
            return try UsageParser.host(text)
        }
        let text = try await HostProcess.sample(host: configuration.nousSSHHost)
        return try UsageParser.host(text)
    }
}

enum HostProcess {
    static func sample(host: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try continuation.resume(returning: self.run(host: host))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func run(host: String) throws -> String {
        let process = Process()
        let output = Pipe()
        let exited = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // Fixed command, no user strings interpreted by the remote shell. No agent
        // forwarding, PTY, auth prompts, host mutation, or persistent remote process.
        let energy = """
        python3 - <<'PY'
        import ctypes
        try:
            n = ctypes.CDLL("libnvidia-ml.so.1")
            if n.nvmlInit_v2() == 0:
                h = ctypes.c_void_p()
                v = ctypes.c_ulonglong()
                if n.nvmlDeviceGetHandleByIndex_v2(0, ctypes.byref(h)) == 0:
                    if n.nvmlDeviceGetTotalEnergyConsumption(h, ctypes.byref(v)) == 0:
                        with open("/proc/uptime") as f:
                            print("ENERGY", v.value, f.read().split()[0])
                n.nvmlShutdown()
        except (OSError, AttributeError):
            pass
        PY
        """
        let command = "LC_ALL=C; export LC_ALL; "
            + "nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,power.draw "
            + "--format=csv,noheader,nounits | sed 's/^/GPU /'; "
            + "free -m; head -n 1 /proc/stat; " + energy
        process.arguments = [
            "-T", "-o", "BatchMode=yes", "-o", "ForwardAgent=no", "-o", "ConnectTimeout=3",
            "-o", "ConnectionAttempts=1", "-o", "StrictHostKeyChecking=yes",
            "-o", "ServerAliveInterval=2", "-o", "ServerAliveCountMax=1", host, command,
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + 6) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            throw UsageError.message("Nous SSH timed out.")
        }
        guard process.terminationStatus == 0 else {
            throw UsageError.message("Nous SSH unavailable. Check the existing SSH connection.")
        }
        let data = try output.fileHandleForReading.read(upToCount: 16385) ?? Data()
        guard data.count <= 16384, let text = String(data: data, encoding: .utf8) else {
            throw UsageError.oversized
        }
        return text
    }
}
