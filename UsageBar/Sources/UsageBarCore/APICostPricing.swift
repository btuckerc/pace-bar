import Foundation

public struct APICostTokens: Sendable, Equatable {
    public let input: Double
    public let cachedInput: Double
    public let cacheWrite: Double
    public let output: Double

    public init(input: Double, cachedInput: Double = 0, cacheWrite: Double = 0, output: Double) {
        self.input = input
        self.cachedInput = cachedInput
        self.cacheWrite = cacheWrite
        self.output = output
    }
}

public struct APICostRecord: Sendable {
    public let id: String
    public let date: Date
    public let model: String
    public let tokens: APICostTokens

    public init(id: String, date: Date, model: String, tokens: APICostTokens) {
        self.id = id
        self.date = date
        self.model = model
        self.tokens = tokens
    }
}

public struct APICostEstimate: Sendable {
    public let usd: Double?
    public let unpricedRecords: Int
    public let pricedRecords: Int
    public let incomplete: Bool
    public let ratesUpdated: Date?
    public let usesT3Pricing: Bool

    public init(
        usd: Double?, unpricedRecords: Int, pricedRecords: Int, incomplete: Bool,
        ratesUpdated: Date?, usesT3Pricing: Bool = false)
    {
        self.usd = usd
        self.unpricedRecords = unpricedRecords
        self.pricedRecords = pricedRecords
        self.incomplete = incomplete
        self.ratesUpdated = ratesUpdated
        self.usesT3Pricing = usesT3Pricing
    }
}

/// T3's “30 days”: today and the preceding 29 calendar days in the viewer's time zone.
public enum APICostWindow {
    public static func bounds(now: Date, calendar: Calendar = .current) -> Range<Date> {
        let day = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -29, to: day) ?? day
        let end = calendar.date(byAdding: .day, value: 1, to: day) ?? now
        return start..<end
    }
}

public actor APICostPricing {
    public struct CatalogRate: Sendable, Equatable, Codable {
        public let input: Double
        public let output: Double
        public let cacheRead: Double?
        public let cacheWrite: Double?

        public init(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
        }
    }

    private struct Cache: Codable {
        let fetchedAt: Date
        let rates: [String: CatalogRate]
    }

    private static let catalogURL = URL(string:
        "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    private let cacheFile: URL
    private let t3Directory: URL?
    private var rates: [String: CatalogRate] = [:]
    private var overrides: [String: CatalogRate] = [:]
    private var ratesUpdated: Date?
    private var loaded = false
    private var attemptedAt: Date?
    private var t3Stamp: String?
    private var pricingIncomplete = false
    private var usesT3Pricing = false

    public init(cacheFile: URL = APICostPricing.defaultCacheFile(), t3Directory: URL? = nil) {
        self.cacheFile = cacheFile
        self.t3Directory = t3Directory
    }

    public func estimate(
        records: [APICostRecord], incomplete: Bool, now: Date = Date(),
        calendar: Calendar = .current) async -> APICostEstimate
    {
        let window = APICostWindow.bounds(now: now, calendar: calendar)
        guard records.contains(where: { window.contains($0.date) }) else {
            return APICostEstimate(
                usd: nil,
                unpricedRecords: 0,
                pricedRecords: 0,
                incomplete: incomplete,
                ratesUpdated: nil)
        }
        await self.loadRatesIfNeeded(now: now)
        var total = 0.0
        var priced = 0
        var unknown = 0
        for record in records where window.contains(record.date) {
            let model = record.model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let rate = self.overrides[model] ?? Self.rate(for: model, in: self.rates),
                  let amount = Self.cost(tokens: record.tokens, rate: rate), (total + amount).isFinite
            else {
                unknown += 1
                continue
            }
            total += amount
            priced += 1
        }
        return APICostEstimate(
            usd: priced > 0 ? total : nil, unpricedRecords: unknown, pricedRecords: priced,
            incomplete: incomplete || unknown > 0 || self.pricingIncomplete,
            ratesUpdated: self.ratesUpdated, usesT3Pricing: self.usesT3Pricing)
    }

    public static func parseCatalog(_ data: Data) -> [String: CatalogRate] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var result: [String: CatalogRate] = [:]
        for (key, value) in object {
            guard let item = value as? [String: Any],
                  let input = Self.number(item["input_cost_per_token"]),
                  let output = Self.number(item["output_cost_per_token"]) else { continue }
            let read = Self.number(item["cache_read_input_token_cost"])
            let write = Self.number(item["cache_creation_input_token_cost"])
            guard item["cache_read_input_token_cost"] == nil || read != nil,
                  item["cache_creation_input_token_cost"] == nil || write != nil else { continue }
            let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            result[normalized] = CatalogRate(
                input: input,
                output: output,
                cacheRead: read ?? input,
                cacheWrite: write ?? input)
        }
        var candidates: [String: CatalogRate] = [:]
        var conflicting = Set<String>()
        for (key, rate) in result {
            let bare = String(key.split(separator: "/").last ?? "")
            guard bare != key, result[bare] == nil else { continue }
            if let existing = candidates[bare], existing != rate { conflicting.insert(bare) }
            candidates[bare] = rate
        }
        for (name, rate) in candidates where !conflicting.contains(name) {
            result[name] = rate
        }
        return result
    }

    public static func cost(tokens: APICostTokens, rate: CatalogRate) -> Double? {
        guard self.valid(rate),
              tokens.input.isFinite, tokens.input >= 0, tokens.output.isFinite, tokens.output >= 0,
              tokens.cachedInput.isFinite, tokens.cachedInput >= 0, tokens.cacheWrite.isFinite, tokens.cacheWrite >= 0,
              tokens.cachedInput + tokens.cacheWrite <= tokens.input else { return nil }
        let result = (tokens.input - tokens.cachedInput - tokens.cacheWrite) * rate.input
            + tokens.cachedInput * (rate.cacheRead ?? rate.input)
            + tokens.cacheWrite * (rate.cacheWrite ?? rate.input) + tokens.output * rate.output
        return result.isFinite && result >= 0 ? result : nil
    }

    public static func rate(for model: String, in catalog: [String: CatalogRate]) -> CatalogRate? {
        let key = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().split(separator: "[", maxSplits: 1)
            .first.map(String.init) ?? ""
        let bare = String(key.split(separator: "/").last ?? "")
        guard !["", "opus", "sonnet", "haiku", "fable", "synthetic", "<synthetic>"].contains(bare) else { return nil }
        return catalog[key]
    }

    private func loadRatesIfNeeded(now: Date) async {
        if self.loadT3Rates(now: now) { return }
        if !self.loaded {
            self.loaded = true
            if let data = try? Self.read(self.cacheFile, limit: 12 * 1024 * 1024),
               let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.fetchedAt <= now,
               cache.rates.values.allSatisfy(Self.valid)
            {
                self.rates = cache.rates
                self.ratesUpdated = cache.fetchedAt
            }
        }
        if let updated = self.ratesUpdated, now.timeIntervalSince(updated) < 86400 { return }
        if let attempted = self.attemptedAt, now.timeIntervalSince(attempted) < 86400 { return }
        self.attemptedAt = now
        do {
            var request = URLRequest(url: Self.catalogURL, timeoutInterval: 10)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 15
            configuration.httpShouldSetCookies = false
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let (bytes, response) = try await session.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 12 * 1024 * 1024 else { return }
                data.append(byte)
            }
            let parsed = Self.parseCatalog(data)
            guard !parsed.isEmpty, !Task.isCancelled else { return }
            self.rates = parsed
            self.ratesUpdated = now
            try FileManager.default.createDirectory(
                at: self.cacheFile.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try JSONEncoder().encode(Cache(fetchedAt: now, rates: parsed)).write(to: self.cacheFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.cacheFile.path)
        } catch {
            // A dated cache stays usable offline; unknown prices never become a fabricated zero.
        }
    }

    private func loadT3Rates(now: Date) -> Bool {
        guard let directory = self.t3Directory else { return false }
        let ratesFile = directory.appendingPathComponent("usage-model-rates.json")
        guard FileManager.default.fileExists(atPath: ratesFile.path) else { return false }
        let settingsFile = directory.appendingPathComponent("settings.json")
        let stamp = [ratesFile, settingsFile].map { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return "\(values?.fileSize ?? -1):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "|")
        if self.t3Stamp == stamp { return true }
        do {
            let data = try Self.read(ratesFile, limit: 12 * 1024 * 1024)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let milliseconds = Self.number(root["fetchedAtMs"]), milliseconds / 1000 <= now.timeIntervalSince1970,
                  let document = root["document"] as? [String: Any]
            else { throw UsageError.message("Invalid T3 pricing cache.") }
            let catalog = try Self.parseCatalog(JSONSerialization.data(withJSONObject: document))
            guard !catalog.isEmpty else { throw UsageError.message("No valid T3 prices.") }
            var overrides: [String: CatalogRate] = [:]
            if FileManager.default.fileExists(atPath: settingsFile.path) {
                let data = try Self.read(settingsFile, limit: 1_048_576)
                guard let settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw UsageError.message("Invalid T3 settings.")
                }
                if let raw = settings["usagePriceOverrides"] {
                    guard let values = raw as? [String: [String: Any]]
                    else { throw UsageError.message("Invalid T3 overrides.") }
                    for (model, value) in values {
                        guard let input = Self.number(value["inputCostPerMillionTokens"]),
                              let output = Self.number(value["outputCostPerMillionTokens"])
                        else {
                            throw UsageError.message("Invalid T3 override price.")
                        }
                        let read = Self.number(value["cacheReadCostPerMillionTokens"])
                        let write = Self.number(value["cacheWriteCostPerMillionTokens"])
                        guard value["cacheReadCostPerMillionTokens"] == nil || read != nil,
                              value["cacheWriteCostPerMillionTokens"] == nil || write != nil
                        else {
                            throw UsageError.message("Invalid T3 cache price.")
                        }
                        overrides[model.trimmingCharacters(in: .whitespacesAndNewlines)] = CatalogRate(
                            input: input / 1_000_000, output: output / 1_000_000,
                            cacheRead: (read ?? input) / 1_000_000, cacheWrite: (write ?? input) / 1_000_000)
                    }
                }
            }
            self.rates = catalog
            self.overrides = overrides
            self.ratesUpdated = Date(timeIntervalSince1970: milliseconds / 1000)
            self.pricingIncomplete = false
            self.usesT3Pricing = true
            self.t3Stamp = stamp
        } catch {
            self.rates = [:]
            self.overrides = [:]
            self.pricingIncomplete = true
            self.usesT3Pricing = false
            // Retry after a transient/partial T3 write. Do not substitute unrelated rates while claiming parity.
        }
        return true
    }

    private static func read(_ file: URL, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw UsageError.oversized }
        return data
    }

    public static func defaultCacheFile() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/usage-bar/litellm-pricing.json")
    }

    private static func valid(_ rate: CatalogRate) -> Bool {
        [rate.input, rate.output, rate.cacheRead ?? rate.input, rate.cacheWrite ?? rate.input]
            .allSatisfy { $0.isFinite && $0 >= 0 }
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        return number.doubleValue
    }
}
