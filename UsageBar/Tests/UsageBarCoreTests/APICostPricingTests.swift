import Foundation
import Testing
@testable import UsageBarCore

@Test func `Pricing includes cached and written input portions without double counting`() {
    let rate = APICostPricing.CatalogRate(input: 1, output: 2, cacheRead: 0.1, cacheWrite: 0.2)
    let tokens = APICostTokens(input: 100, cachedInput: 20, cacheWrite: 10, output: 5)
    #expect(APICostPricing.cost(tokens: tokens, rate: rate) == 84)
}

@Test func `Catalog parser rejects malformed and negative required rates`() {
    let data = Data(#"""
    {
      "good": {"input_cost_per_token": 0.000001, "output_cost_per_token": 0.000002},
      "negative": {"input_cost_per_token": -1, "output_cost_per_token": 1},
      "missing": {"input_cost_per_token": 1},
      "boolean": {"input_cost_per_token": true, "output_cost_per_token": 1},
      "bad-cache": {"input_cost_per_token": 1, "output_cost_per_token": 1, "cache_read_input_token_cost": -1},
      "nan": {"input_cost_per_token": "NaN", "output_cost_per_token": 1}
    }
    """#.utf8)
    let catalog = APICostPricing.parseCatalog(data)
    #expect(catalog["good"] != nil)
    #expect(catalog["negative"] == nil)
    #expect(catalog["missing"] == nil)
    #expect(catalog["nan"] == nil)
    #expect(catalog["boolean"] == nil)
    #expect(catalog["bad-cache"] == nil)
}

@Test func `T3 pricing aliases agree across providers or remain explicitly unpriced`() throws {
    let document: [String: Any] = [
        "vendor-a/example-model": ["input_cost_per_token": 1, "output_cost_per_token": 2],
        "vendor-b/example-model": ["input_cost_per_token": 1, "output_cost_per_token": 2],
        "vendor-a/ambiguous-model": ["input_cost_per_token": 1, "output_cost_per_token": 2],
        "vendor-b/ambiguous-model": ["input_cost_per_token": 9, "output_cost_per_token": 2],
        "opus": ["input_cost_per_token": 1, "output_cost_per_token": 2],
    ]
    let rates = try APICostPricing.parseCatalog(JSONSerialization.data(withJSONObject: document))
    let tokens = APICostTokens(input: 10, output: 3)
    let rate = try #require(APICostPricing.rate(for: " EXAMPLE-MODEL[1m] ", in: rates))
    #expect(APICostPricing.cost(tokens: tokens, rate: rate) == 16)
    #expect(APICostPricing.rate(for: "ambiguous-model", in: rates) == nil)
    #expect(APICostPricing.rate(for: "opus", in: rates) == nil)
}

@Test func `Invalid token splits and nonfinite prices never produce a cost`() {
    #expect(APICostPricing.cost(
        tokens: APICostTokens(input: 5, cachedInput: 6, output: 1),
        rate: APICostPricing.CatalogRate(input: 1, output: 2)) == nil)
    #expect(APICostPricing.cost(
        tokens: APICostTokens(input: 5, output: 1),
        rate: APICostPricing.CatalogRate(input: .infinity, output: 2)) == nil)
}

@Test func `Dated cached pricing estimates only recorded in-window usage and exposes unknown coverage`() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("rates.json")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let cache: [String: Any] = [
        "fetchedAt": now.timeIntervalSinceReferenceDate,
        "rates": ["example-model": ["input": 1.0, "output": 2.0, "cacheRead": 0.1, "cacheWrite": 0.2]],
    ]
    try JSONSerialization.data(withJSONObject: cache).write(to: file)
    let pricing = APICostPricing(cacheFile: file)
    let tokens = APICostTokens(input: 100, cachedInput: 20, cacheWrite: 10, output: 5)
    let known = APICostRecord(id: "known", date: now, model: "example-model", tokens: tokens)
    let unknown = APICostRecord(id: "unknown", date: now, model: "unpriced-model", tokens: tokens)
    let expired = APICostRecord(
        id: "old", date: now.addingTimeInterval(-30 * 86400 - 1), model: "example-model", tokens: tokens)
    let result = await pricing.estimate(records: [known, unknown, expired], incomplete: false, now: now)
    #expect(result.usd == 84)
    #expect(result.unpricedRecords == 1)
    #expect(result.incomplete)
    #expect(result.ratesUpdated == now)
    let absent = await pricing.estimate(records: [], incomplete: false, now: now)
    #expect(absent.usd == nil)
    let unpriced = await pricing.estimate(records: [unknown], incomplete: false, now: now)
    #expect(unpriced.usd == nil)
    #expect(unpriced.unpricedRecords == 1)
}

@Test func `T3 saved catalog and exact custom overrides are used without a network refresh`() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let source: [String: Any] = [
        "fetchedAtMs": now.addingTimeInterval(-90000).timeIntervalSince1970 * 1000,
        "document": ["example-model": ["input_cost_per_token": 1, "output_cost_per_token": 2]],
    ]
    let settings: [String: Any] = ["usagePriceOverrides": [
        "custom-model": ["inputCostPerMillionTokens": 1_000_000, "outputCostPerMillionTokens": 3_000_000],
    ]]
    try JSONSerialization.data(withJSONObject: source).write(to: root.appendingPathComponent("usage-model-rates.json"))
    try JSONSerialization.data(withJSONObject: settings).write(to: root.appendingPathComponent("settings.json"))
    let pricing = APICostPricing(cacheFile: root.appendingPathComponent("native.json"), t3Directory: root)
    let records = [
        APICostRecord(id: "1", date: now, model: "example-model", tokens: APICostTokens(input: 10, output: 2)),
        APICostRecord(id: "2", date: now, model: "custom-model", tokens: APICostTokens(input: 10, output: 2)),
    ]
    let result = await pricing.estimate(records: records, incomplete: false, now: now)
    #expect(result.usd == 30)
    #expect(result.usesT3Pricing)
    #expect(!result.incomplete)
    #expect(result.ratesUpdated == now.addingTimeInterval(-90000))
}

@Test func `Thirty calendar days remain aligned with T3 across daylight saving`() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
    let now = try #require(ISO8601DateFormatter().date(from: "2026-03-20T18:00:00Z"))
    let window = APICostWindow.bounds(now: now, calendar: calendar)
    #expect(window.lowerBound == ISO8601DateFormatter().date(from: "2026-02-19T05:00:00Z"))
    #expect(window.upperBound == ISO8601DateFormatter().date(from: "2026-03-21T04:00:00Z"))
}
