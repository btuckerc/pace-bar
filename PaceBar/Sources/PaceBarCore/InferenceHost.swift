import Foundation

public struct InferenceHost: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var serverURL: String
    public var sshHost: String?
    public var metricsURL: String?
    public var hostUtilization: Bool
    public var electricityUSDPerKWh: Double?
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        name: String = "nous",
        serverURL: String = "http://nous:8080",
        sshHost: String? = "nous",
        metricsURL: String? = nil,
        hostUtilization: Bool = true,
        electricityUSDPerKWh: Double? = nil,
        enabled: Bool = true)
    {
        self.id = id
        self.name = name
        self.serverURL = serverURL
        self.sshHost = sshHost
        self.metricsURL = metricsURL
        self.hostUtilization = hostUtilization
        self.electricityUSDPerKWh = electricityUSDPerKWh
        self.enabled = enabled
    }

    public var normalizedOrigin: String {
        var parts = URLComponents(string: self.serverURL)!
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if (parts.scheme == "http" && parts.port == 80) ||
            (parts.scheme == "https" && parts.port == 443) { parts.port = nil }
        parts.path = ""
        return parts.string!
    }

    public func validate() throws {
        guard !self.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw UsageError.message("Enter a host name.") }
        for origin in [self.serverURL] + [self.metricsURL].compactMap(\.self).filter({ !$0.isEmpty }) {
            guard let url = URL(string: origin), ["http", "https"].contains(url.scheme), url.host != nil,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.isEmpty || url.path == "/"
            else { throw UsageError.message("Host URLs must be HTTP(S) server origins.") }
        }
        if let ssh = self.sshHost {
            guard !ssh.isEmpty, !ssh.hasPrefix("-"),
                  ssh.range(of: "^[A-Za-z0-9_.@-]+$", options: .regularExpression) != nil
            else { throw UsageError.message("Invalid SSH host.") }
        }
        if let rate = self.electricityUSDPerKWh,
           !rate
               .isFinite || rate <
               0 { throw UsageError.message("Electricity rate must be a nonnegative USD/kWh amount.") }
    }
}

public struct HostReading: Sendable {
    public var nous: NousSnapshot?
    public var lifetime: NousLifetimeTotals?
    public var hardware: HostSnapshot?
    public var cpuPercent: Double?
    public var energy = GPUEnergy()
    /// Set while the inference server answers 503 on purpose, such as while its GPU is lent out.
    public var pause: Pause?
    public init() {}

    public struct Pause: Equatable, Sendable {
        public var until: Date?
        public var reason: String?

        /// `until` is the lease's hard cap; the server may return sooner.
        public var label: String {
            self.until.map { "Paused · back by \($0.formatted(date: .omitted, time: .shortened))" } ?? "Paused"
        }
    }

    /// Keep accumulated history, but never expose an old sample as current inference.
    public mutating func inferenceFailed() {
        self.nous = nil
        self.pause = nil
    }

    public mutating func inferencePaused(until: Date?, reason: String?) {
        self.nous = nil
        self.pause = Pause(until: until, reason: reason)
    }
}
