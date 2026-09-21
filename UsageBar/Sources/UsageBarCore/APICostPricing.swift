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
    public let weekUSD: Double?
    public let unpricedRecords: Int
    public let pricedRecords: Int
    public let incomplete: Bool
    public let ratesUpdated: Date?

    public init(
        usd: Double?, unpricedRecords: Int, pricedRecords: Int, incomplete: Bool,
        ratesUpdated: Date?, weekUSD: Double? = nil)
    {
        self.usd = usd
        self.weekUSD = weekUSD
        self.unpricedRecords = unpricedRecords
        self.pricedRecords = pricedRecords
        self.incomplete = incomplete
        self.ratesUpdated = ratesUpdated
    }
}

/// Calendar windows include today and the preceding local calendar days.
public enum APICostWindow {
    public static func bounds(now: Date, calendar: Calendar = .current) -> Range<Date> {
        self.bounds(now: now, days: 30, calendar: calendar)
    }

    public static func weekBounds(now: Date, calendar: Calendar = .current) -> Range<Date> {
        self.bounds(now: now, days: 7, calendar: calendar)
    }

    private static func bounds(now: Date, days: Int, calendar: Calendar) -> Range<Date> {
        let day = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: day) ?? day
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
    private var rates: [String: CatalogRate] = [:]
    private var ratesUpdated: Date?
    private var loaded = false
    private var attemptedAt: Date?

    /// Standard API rates from CodexBar's OpenAI pricing table; not fast/batch/long-context billing.
    /// These keep known models priceable offline and when the public catalog has not caught up.
    private static let bundled: [String: CatalogRate] = [
        "gpt-5": .init(input: 1.25e-6, output: 1e-5, cacheRead: 1.25e-7),
        "gpt-5-codex": .init(input: 1.25e-6, output: 1e-5, cacheRead: 1.25e-7),
        "gpt-5-mini": .init(input: 2.5e-7, output: 2e-6, cacheRead: 2.5e-8),
        "gpt-5-nano": .init(input: 5e-8, output: 4e-7, cacheRead: 5e-9),
        "gpt-5-pro": .init(input: 1.5e-5, output: 1.2e-4),
        "gpt-5.1": .init(input: 1.25e-6, output: 1e-5, cacheRead: 1.25e-7),
        "gpt-5.1-codex": .init(input: 1.25e-6, output: 1e-5, cacheRead: 1.25e-7),
        "gpt-5.1-codex-max": .init(input: 1.25e-6, output: 1e-5, cacheRead: 1.25e-7),
        "gpt-5.1-codex-mini": .init(input: 2.5e-7, output: 2e-6, cacheRead: 2.5e-8),
        "gpt-5.2": .init(input: 1.75e-6, output: 1.4e-5, cacheRead: 1.75e-7),
        "gpt-5.2-codex": .init(input: 1.75e-6, output: 1.4e-5, cacheRead: 1.75e-7),
        "gpt-5.2-pro": .init(input: 2.1e-5, output: 1.68e-4),
        "gpt-5.3-codex": .init(input: 1.75e-6, output: 1.4e-5, cacheRead: 1.75e-7),
        "gpt-5.3-codex-spark": .init(input: 0, output: 0, cacheRead: 0),
        "gpt-5.4": .init(input: 2.5e-6, output: 1.5e-5, cacheRead: 2.5e-7),
        "gpt-5.4-mini": .init(input: 7.5e-7, output: 4.5e-6, cacheRead: 7.5e-8),
        "gpt-5.4-nano": .init(input: 2e-7, output: 1.25e-6, cacheRead: 2e-8),
        "gpt-5.4-pro": .init(input: 3e-5, output: 1.8e-4),
        "gpt-5.5": .init(input: 5e-6, output: 3e-5, cacheRead: 5e-7),
        "gpt-5.5-pro": .init(input: 3e-5, output: 1.8e-4),
        "gpt-5.6-sol": .init(input: 5e-6, output: 3e-5, cacheRead: 5e-7, cacheWrite: 6.25e-6),
        "gpt-5.6-terra": .init(input: 2e-6, output: 1.2e-5, cacheRead: 2e-7, cacheWrite: 2.5e-6),
        "gpt-5.6-luna": .init(input: 2e-7, output: 1.2e-6, cacheRead: 2e-8, cacheWrite: 2.5e-7),
        "gpt-6-astra": .init(input: 1e-5, output: 5e-5, cacheRead: 1e-6, cacheWrite: 1.25e-5),
    ]

    public init(cacheFile: URL = APICostPricing.defaultCacheFile()) {
        self.cacheFile = cacheFile
    }

    public func estimate(
        records: [APICostRecord], incomplete: Bool, now: Date = Date(),
        calendar: Calendar = .current) async -> APICostEstimate
    {
        let month = APICostWindow.bounds(now: now, calendar: calendar)
        let week = APICostWindow.weekBounds(now: now, calendar: calendar)
        guard records.contains(where: { month.contains($0.date) }) else {
            return APICostEstimate(
                usd: nil, unpricedRecords: 0, pricedRecords: 0, incomplete: incomplete, ratesUpdated: nil)
        }
        await self.loadRatesIfNeeded(now: now)
        var total = 0.0
        var weekTotal = 0.0
        var priced = 0
        var unknown = 0
        var weekPriced = 0
        for record in records where month.contains(record.date) {
            guard let rate = Self.rate(for: record.model, in: self.rates),
                  let amount = Self.cost(tokens: record.tokens, rate: rate), (total + amount).isFinite
            else {
                unknown += 1
                continue
            }
            total += amount
            priced += 1
            if week.contains(record.date) {
                weekTotal += amount
                weekPriced += 1
            }
        }
        return APICostEstimate(
            usd: priced > 0 ? total : nil, unpricedRecords: unknown, pricedRecords: priced,
            incomplete: incomplete || unknown > 0, ratesUpdated: self.ratesUpdated,
            weekUSD: weekPriced > 0 ? weekTotal : nil)
    }

    public static func parseCatalog(_ data: Data) -> [String: CatalogRate] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var result: [String: CatalogRate] = [:]
        for (key, value) in object {
            guard let item = value as? [String: Any],
                  let input = self.number(item["input_cost_per_token"]),
                  let output = self.number(item["output_cost_per_token"]) else { continue }
            let read = self.number(item["cache_read_input_token_cost"])
            let write = self.number(item["cache_creation_input_token_cost"])
            guard item["cache_read_input_token_cost"] == nil || read != nil,
                  item["cache_creation_input_token_cost"] == nil || write != nil else { continue }
            result[key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = CatalogRate(
                input: input, output: output, cacheRead: read ?? input, cacheWrite: write ?? input)
        }
        var candidates: [String: CatalogRate] = [:]
        var conflicting = Set<String>()
        for (key, rate) in result {
            let bare = String(key.split(separator: "/").last ?? "")
            guard bare != key, result[bare] == nil else { continue }
            if let old = candidates[bare], old != rate { conflicting.insert(bare) }
            candidates[bare] = rate
        }
        for (name, rate) in candidates where !conflicting.contains(name) {
            result[name] = rate
        }
        return result
    }

    public static func cost(tokens: APICostTokens, rate: CatalogRate) -> Double? {
        guard self.valid(rate), tokens.input.isFinite, tokens.input >= 0, tokens.output.isFinite, tokens.output >= 0,
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
        guard !["", "opus", "sonnet", "haiku", "fable", "synthetic", "<synthetic>"].contains(key) else { return nil }
        if let exact = catalog[key] { return exact }
        let bare: String = if key.hasPrefix("openai/") || key.hasPrefix("openai-codex/") {
            String(key.split(separator: "/", maxSplits: 1).last ?? "")
        } else {
            key
        }
        let normalized = switch bare {
        case "gpt-5.6": "gpt-5.6-sol"
        case "gpt-reserve": "gpt-5.6-luna"
        default: bare
        }
        return catalog[normalized] ?? self.bundled[normalized]
    }

    private func loadRatesIfNeeded(now: Date) async {
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
                at: self.cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Cache(fetchedAt: now, rates: parsed)).write(to: self.cacheFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.cacheFile.path)
        } catch {
            // Dated cache and bundled known prices remain usable offline; unknown models stay unpriced.
        }
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
