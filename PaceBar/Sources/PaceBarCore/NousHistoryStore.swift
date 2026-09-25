import CryptoKit
import Foundation

public struct NousLifetimeTotals: Sendable, Equatable {
    public let promptTokens: Double?
    public let cachedTokens: Double?
    public let outputTokens: Double?

    public init(promptTokens: Double? = nil, cachedTokens: Double? = nil, outputTokens: Double? = nil) {
        self.promptTokens = promptTokens
        self.cachedTokens = cachedTokens
        self.outputTokens = outputTokens
    }
}

/// Persists cumulative llama-server counters without retaining host names or model paths.
public actor NousHistoryStore {
    private static let maxFileSize = 1_048_576
    fileprivate static let maxHosts = 16
    fileprivate static let maxModelsPerHost = 128
    fileprivate static let maxModels = 512

    private let file: URL
    private var loaded = false
    private var available = true
    private var history = History()

    public init(file: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/pace-bar/nous-history.json"))
    {
        self.file = file
    }

    public func snapshot(origin: String) -> (NousLifetimeTotals, Bool) {
        self.loadIfNeeded()
        guard self.available else { return (NousLifetimeTotals(), false) }
        return (self.totals(for: Self.originKey(origin)), true)
    }

    public func energySnapshot(origin: String) -> (GPUEnergy, Bool) {
        self.loadIfNeeded()
        guard self.available else { return (GPUEnergy(), false) }
        return (self.history.hosts[Self.originKey(origin)]?.energy ?? GPUEnergy(), true)
    }

    public func recordEnergy(_ snapshot: HostSnapshot, origin: String) -> (GPUEnergy, Bool) {
        self.loadIfNeeded()
        guard self.available else { return (GPUEnergy(), false) }
        let hostKey = Self.originKey(origin)
        var next = self.history
        var host = next.hosts[hostKey] ?? HostHistory()
        let prior = host.energy ?? GPUEnergy()
        var energy = prior
        energy.record(snapshot)
        guard energy.isValid else { return (prior, false) }
        host.energy = energy
        if next.hosts[hostKey] == nil {
            guard next.hosts.count < Self.maxHosts else { return (prior, false) }
        }
        next.hosts[hostKey] = host
        guard next == self.history || self.save(next) else { return (prior, false) }
        self.history = next
        return (energy, true)
    }

    public func record(_ snapshot: NousSnapshot, origin: String) -> (NousLifetimeTotals, Bool) {
        self.loadIfNeeded()
        guard self.available else { return (NousLifetimeTotals(), false) }
        let hostKey = Self.originKey(origin)
        var next = self.history
        var metadataChanged = false
        let activeModelKey = snapshot.model.map(Self.hash)
        if !snapshot.unloadedModels.isEmpty, var host = next.hosts[hostKey] {
            for unloaded in snapshot.unloadedModels {
                let key = Self.hash(unloaded)
                // A contradictory inventory must not retire the model being sampled.
                guard key != activeModelKey, var model = host.models[key] else { continue }
                if model.clearBaselines() {
                    host.models[key] = model
                    metadataChanged = true
                }
            }
            if metadataChanged { next.hosts[hostKey] = host }
        }
        guard let model = snapshot.model else {
            if metadataChanged {
                guard self.save(next) else { return (self.totals(for: hostKey), false) }
                self.history = next
            }
            return (self.totals(for: hostKey), true)
        }
        guard Self.valid(snapshot.promptTokens), Self.valid(snapshot.cachedTokens), Self.valid(snapshot.outputTokens)
        else { return (self.totals(for: hostKey), false) }

        let modelKey = Self.hash(model)
        var host = next.hosts[hostKey] ?? HostHistory()
        if next.hosts[hostKey] == nil, next.hosts.count >= Self.maxHosts {
            return (self.totals(for: hostKey), false)
        }
        if host.models[modelKey] == nil {
            guard host.models.count < Self.maxModelsPerHost, next.modelCount < Self.maxModels else {
                return (self.totals(for: hostKey), false)
            }
            host.models[modelKey] = ModelHistory()
            next.modelCount += 1
        }
        guard var modelHistory = host.models[modelKey] else { return (self.totals(for: hostKey), false) }
        modelHistory.apply(prompt: snapshot.promptTokens, cached: snapshot.cachedTokens, output: snapshot.outputTokens)
        guard modelHistory.isValid else { return (self.totals(for: hostKey), false) }
        host.models[modelKey] = modelHistory
        next.hosts[hostKey] = host
        let changed = next != self.history
        if changed {
            guard self.save(next) else {
                return (self.totals(for: hostKey), false)
            }
            self.history = next
        }
        return (self.totals(for: hostKey), true)
    }

    private func loadIfNeeded() {
        guard !self.loaded else { return }
        self.loaded = true
        guard FileManager.default.fileExists(atPath: self.file.path) else { return }
        guard let size = try? self.file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= Self.maxFileSize,
              let data = try? Data(contentsOf: self.file),
              let decoded = try? JSONDecoder().decode(History.self, from: data),
              decoded.isWithinBounds
        else {
            self.available = false
            return
        }
        self.history = decoded
    }

    private func save(_ value: History) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: self.file.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(value)
            guard data.count <= Self.maxFileSize else { return false }
            try data.write(to: self.file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.file.path)
            return true
        } catch {
            return false
        }
    }

    private func totals(for hostKey: String) -> NousLifetimeTotals {
        guard let host = self.history.hosts[hostKey] else { return NousLifetimeTotals() }
        var prompt: Double?
        var cached: Double?
        var output: Double?
        for model in host.models.values {
            prompt = Self.add(prompt, model.prompt.total)
            cached = Self.add(cached, model.cached.total)
            output = Self.add(output, model.output.total)
        }
        return NousLifetimeTotals(promptTokens: prompt, cachedTokens: cached, outputTokens: output)
    }

    private static func valid(_ value: Double?) -> Bool {
        guard let value else { return true }
        return value.isFinite && value >= 0
    }

    private static func add(_ lhs: Double?, _ rhs: Double?) -> Double? {
        guard let rhs else { return lhs }
        guard let lhs else { return rhs }
        let result = lhs + rhs
        return result.isFinite ? result : nil
    }

    private static func originKey(_ origin: String) -> String {
        if var components = URLComponents(string: origin), let scheme = components.scheme, let host = components.host {
            let normalizedScheme = scheme.lowercased()
            let normalizedHost = host.lowercased()
            let port = components.port
            let isDefault = (normalizedScheme == "http" && port == 80) || (normalizedScheme == "https" && port == 443)
            components.scheme = normalizedScheme
            components.host = normalizedHost
            components.path = ""
            components.query = nil
            components.fragment = nil
            if isDefault { components.port = nil }
            return Self.hash(components.string?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? origin)
        }
        return Self
            .hash(origin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private struct Counter: Codable, Equatable {
    var baseline: Double?
    var total: Double?
}

private struct ModelHistory: Codable, Equatable {
    var prompt = Counter()
    var cached = Counter()
    var output = Counter()

    var isValid: Bool {
        [
            self.prompt.baseline,
            self.prompt.total,
            self.cached.baseline,
            self.cached.total,
            self.output.baseline,
            self.output.total,
        ]
            .compactMap(\.self).allSatisfy { $0.isFinite && $0 >= 0 }
    }

    mutating func apply(prompt: Double?, cached: Double?, output: Double?) {
        Self.apply(&self.prompt, value: prompt)
        Self.apply(&self.cached, value: cached)
        Self.apply(&self.output, value: output)
    }

    mutating func clearBaselines() -> Bool {
        let hadBaseline = self.prompt.baseline != nil || self.cached.baseline != nil || self.output.baseline != nil
        self.prompt.baseline = nil
        self.cached.baseline = nil
        self.output.baseline = nil
        return hadBaseline
    }

    private static func apply(_ counter: inout Counter, value: Double?) {
        guard let value else { return }
        guard let baseline = counter.baseline else {
            counter.baseline = value
            // The first observation already represents work performed by the running
            // server, so seed the lifetime value with its complete current counter.
            counter.total = (counter.total ?? 0) + value
            return
        }
        let delta = value >= baseline ? value - baseline : value
        counter.total = (counter.total ?? 0) + delta
        counter.baseline = value
    }
}

private struct HostHistory: Codable, Equatable {
    var models: [String: ModelHistory] = [:]
    var energy: GPUEnergy?
}

private struct History: Codable, Equatable {
    var hosts: [String: HostHistory] = [:]
    var modelCount = 0

    var isWithinBounds: Bool {
        self.hosts.count <= NousHistoryStore.maxHosts && self.hosts.values
            .allSatisfy {
                $0.models.count <= NousHistoryStore.maxModelsPerHost
                    && ($0.energy?.isValid ?? true)
            }
            && self.modelCount <= NousHistoryStore.maxModels
            && self.hosts.values.reduce(0) { $0 + $1.models.count } == self.modelCount
    }
}
