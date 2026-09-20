import Foundation

public struct QuotaWindow: Identifiable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let usedPercent: Double
    public let resetsAt: Date

    public var remainingPercent: Double {
        max(0, min(100, 100 - self.usedPercent))
    }
}

public struct CodexSnapshot: Sendable {
    public let windows: [QuotaWindow]
    public let plan: String?
}

public struct OpenRouterSnapshot: Sendable {
    public let balance: Double?
    public let today: Double?
    public let week: Double?
    public let month: Double?
    public let keyRemaining: Double?
    public let warning: String?
}

public struct NousSnapshot: Sendable {
    public let model: String?
    public let promptTokens: Double?
    public let cachedTokens: Double?
    public let outputTokens: Double?
    public let generationTPS: Double?
    public let promptTPS: Double?
    public let processing: Double?
    public let queued: Double?

    public static let idle = NousSnapshot(
        model: nil, promptTokens: nil, cachedTokens: nil, outputTokens: nil,
        generationTPS: nil, promptTPS: nil, processing: nil, queued: nil)
}

public struct HostSnapshot: Sendable {
    public let gpuPercent: Double?
    public let vramUsedMiB: Double?
    public let vramTotalMiB: Double?
    public let watts: Double?
    public let ramUsedMiB: Double?
    public let ramTotalMiB: Double?
    public let cpu: CPUCounters?
}

public struct CPUCounters: Sendable {
    public let total: Double
    public let idle: Double

    public func usage(since previous: CPUCounters?) -> Double? {
        guard let previous else { return nil }
        let totalDelta = self.total - previous.total
        let idleDelta = self.idle - previous.idle
        guard totalDelta > 0, idleDelta >= 0, idleDelta <= totalDelta else { return nil }
        return 100 * (totalDelta - idleDelta) / totalDelta
    }
}

public enum UsageError: LocalizedError, Sendable {
    case message(String)
    case http(Int)
    case oversized

    public var errorDescription: String? {
        switch self {
        case let .message(text): text
        case let .http(status): "Request failed (HTTP \(status))."
        case .oversized: "Response exceeded the size limit."
        }
    }
}

public enum UsageParser {
    public static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= 1_048_576 else { throw UsageError.oversized }
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.message("Unexpected response format.")
        }
        return value
    }

    public static func number(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        let result: Double?
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            result = number.doubleValue
        } else if let string = value as? String {
            result = Double(string)
        } else {
            result = nil
        }
        return result.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    /// Adapted from CodexBar's CodexOAuthUsageFetcher response contract. Additional
    /// windows are additive: malformed optional lanes never remove valid base lanes.
    public static func codex(_ data: Data) throws -> CodexSnapshot {
        let root = try self.object(data)
        var windows = self.windows(root["rate_limit"], prefix: "Codex")
        for (index, extra) in (root["additional_rate_limits"] as? [[String: Any]] ?? []).enumerated() {
            let name = extra["limit_name"] as? String ?? extra["metered_feature"] as? String ?? "Additional \(index + 1)"
            windows += self.windows(extra["rate_limit"], prefix: name)
        }
        guard !windows.isEmpty else { throw UsageError.message("No subscription quota windows returned.") }
        return CodexSnapshot(windows: windows, plan: root["plan_type"] as? String)
    }

    private static func windows(_ raw: Any?, prefix: String) -> [QuotaWindow] {
        guard let limits = raw as? [String: Any] else { return [] }
        return ["primary_window", "secondary_window"].compactMap { key in
            guard let value = limits[key] as? [String: Any],
                  let used = self.number(value["used_percent"]),
                  let reset = self.number(value["reset_at"]), reset < 253_402_300_800,
                  let seconds = self.number(value["limit_window_seconds"]), seconds > 0
            else { return nil }
            let period = switch seconds {
            case 18000: "5 hours"
            case 604_800: "Weekly"
            default: "\(Int(min(seconds / 3600, 1_000_000))) hours"
            }
            return QuotaWindow(
                id: "\(prefix)-\(key)", label: prefix == "Codex" ? period : "\(prefix) · \(period)",
                usedPercent: used, resetsAt: Date(timeIntervalSince1970: reset))
        }
    }

    public static func openRouter(key: Data?, credits: Data?, warning: String?) throws -> OpenRouterSnapshot {
        let keyValues = try key.map(self.object)?["data"] as? [String: Any]
        let creditValues = try credits.map(self.object)?["data"] as? [String: Any]
        let balance: Double? = if let total = self.number(creditValues?["total_credits"]),
                                  let spent = self.number(creditValues?["total_usage"])
        {
            max(0, total - spent)
        } else {
            nil
        }
        let today = self.number(keyValues?["usage_daily"])
        let week = self.number(keyValues?["usage_weekly"])
        let month = self.number(keyValues?["usage_monthly"])
        let remaining = self.number(keyValues?["limit_remaining"])
        guard balance != nil || today != nil || week != nil || month != nil || remaining != nil else {
            throw UsageError.message(warning ?? "No OpenRouter balance or usage returned.")
        }
        return OpenRouterSnapshot(
            balance: balance, today: today, week: week, month: month, keyRemaining: remaining, warning: warning)
    }

    public static func loadedModel(_ data: Data) throws -> String? {
        let root = try self.object(data)
        guard let models = root["data"] as? [[String: Any]] else {
            throw UsageError.message("Invalid model inventory.")
        }
        let loaded = models.filter { ($0["status"] as? [String: Any])?["value"] as? String == "loaded" }
        if let model = loaded.first?["id"] as? String { return model }
        // A single-model server has no router status field.
        if models.count == 1, models[0]["status"] == nil { return models[0]["id"] as? String }
        return nil
    }

    public static func nous(_ data: Data, model: String) throws -> NousSnapshot {
        guard data.count <= 65536, let text = String(data: data, encoding: .utf8) else {
            throw UsageError.oversized
        }
        var metrics: [String: Double] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, !parts[0].contains("{"),
                  let number = Double(parts[1]), number.isFinite, number >= 0
            else { continue }
            metrics[String(parts[0])] = number
        }
        guard metrics["llamacpp:tokens_predicted_total"] != nil,
              metrics["llamacpp:prompt_tokens_total"] != nil
        else { throw UsageError.message("llama-server token counters unavailable.") }
        return NousSnapshot(
            model: model,
            promptTokens: metrics["llamacpp:prompt_tokens_total"],
            cachedTokens: metrics["llamacpp:prompt_tokens_cached_total"],
            outputTokens: metrics["llamacpp:tokens_predicted_total"],
            generationTPS: metrics["llamacpp:predicted_tokens_seconds"],
            promptTPS: metrics["llamacpp:prompt_tokens_seconds"],
            processing: metrics["llamacpp:requests_processing"],
            queued: metrics["llamacpp:requests_deferred"])
    }

    public static func host(_ text: String) throws -> HostSnapshot {
        let lines = text.split(separator: "\n").map(String.init)
        let gpu = lines.first(where: { $0.hasPrefix("GPU ") })?.dropFirst(4)
            .split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) } ?? []
        let memory = lines.first(where: { $0.hasPrefix("Mem:") })?
            .split(whereSeparator: \.isWhitespace).dropFirst().compactMap { Double($0) } ?? []
        let cpuValues = lines.first(where: { $0.hasPrefix("cpu ") })?
            .split(whereSeparator: \.isWhitespace).dropFirst().prefix(8).compactMap { Double($0) } ?? []
        let cpu = cpuValues.count >= 5
            ? CPUCounters(total: cpuValues.reduce(0, +), idle: cpuValues[3] + cpuValues[4]) : nil
        guard gpu.count >= 4 || memory.count >= 2 || cpu != nil else {
            throw UsageError.message("Host utilization unavailable.")
        }
        return HostSnapshot(
            gpuPercent: gpu.count >= 4 ? gpu[0] : nil,
            vramUsedMiB: gpu.count >= 4 ? gpu[1] : nil,
            vramTotalMiB: gpu.count >= 4 ? gpu[2] : nil,
            watts: gpu.count >= 4 ? gpu[3] : nil,
            ramUsedMiB: memory.count >= 2 ? memory[1] : nil,
            ramTotalMiB: memory.count >= 2 ? memory[0] : nil, cpu: cpu)
    }
}
