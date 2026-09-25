import Foundation
import Testing
@testable import PaceBarCore

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
    #expect(catalog["good"] != nil); #expect(catalog["negative"] == nil); #expect(catalog["missing"] == nil)
    #expect(catalog["nan"] == nil); #expect(catalog["boolean"] == nil); #expect(catalog["bad-cache"] == nil)
}

@Test func `Catalog wins and bundled Codex rates work without T3`() throws {
    let data = Data(#"""
    {
      "vendor/gpt-5": {"input_cost_per_token": 1, "output_cost_per_token": 2},
      "example-model": {"input_cost_per_token": 3, "output_cost_per_token": 4}
    }
    """#.utf8)
    let rates = APICostPricing.parseCatalog(data)
    let catalogRate = try #require(APICostPricing.rate(for: "vendor/gpt-5", in: rates))
    #expect(catalogRate.input == 1)
    let bundled = try #require(APICostPricing.rate(for: "gpt-5", in: [:]))
    let cost = APICostPricing.cost(
        tokens: APICostTokens(input: 1_000_000, cachedInput: 200_000, output: 100_000), rate: bundled)
    #expect(cost == 2.025)
    #expect(APICostPricing.rate(for: "unrelated/gpt-5", in: [:]) == nil)
    #expect(APICostPricing.rate(for: "unknown-fictional-model", in: rates) == nil)
}

@Test func `Invalid token splits and nonfinite prices never produce a cost`() {
    #expect(APICostPricing.cost(
        tokens: APICostTokens(input: 5, cachedInput: 6, output: 1),
        rate: .init(input: 1, output: 2)) == nil)
    #expect(APICostPricing
        .cost(tokens: APICostTokens(input: 5, output: 1), rate: .init(input: .infinity, output: 2)) == nil)
}

@Test func `Dated cached pricing estimates month and week independently`() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default
        .createDirectory(at: root, withIntermediateDirectories: true); defer
    {
        try? FileManager.default.removeItem(at: root)
    }
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
    let old = APICostRecord(
        id: "old",
        date: now.addingTimeInterval(-30 * 86400 - 1),
        model: "example-model",
        tokens: tokens)
    let monthOnly = APICostRecord(
        id: "month-only", date: now.addingTimeInterval(-10 * 86400), model: "example-model", tokens: tokens)
    let result = await pricing.estimate(records: [known, unknown, old, monthOnly], incomplete: false, now: now)
    #expect(result.usd == 168)
    #expect(result.weekUSD == 84)
    #expect(result.unpricedRecords == 1)
    #expect(result.incomplete)
    #expect(result.ratesUpdated == now)
    let absent = await pricing
        .estimate(records: [], incomplete: false, now: now); #expect(absent.usd == nil); #expect(absent.weekUSD == nil)
    let unpriced = await pricing.estimate(records: [unknown], incomplete: false, now: now)
    #expect(unpriced.usd == nil)
    #expect(unpriced.weekUSD == nil)
    #expect(unpriced.unpricedRecords == 1)
}

@Test func `Thirty calendar days and seven calendar days remain local across daylight saving`() throws {
    var calendar = Calendar(identifier: .gregorian); calendar
        .timeZone = try #require(TimeZone(identifier: "America/New_York"))
    let now = try #require(ISO8601DateFormatter().date(from: "2026-03-20T18:00:00Z"))
    let month = APICostWindow.bounds(now: now, calendar: calendar), week = APICostWindow.weekBounds(
        now: now,
        calendar: calendar)
    #expect(month.lowerBound == ISO8601DateFormatter().date(from: "2026-02-19T05:00:00Z")); #expect(month
        .upperBound == ISO8601DateFormatter().date(from: "2026-03-21T04:00:00Z"))
    #expect(week.lowerBound == ISO8601DateFormatter().date(from: "2026-03-14T04:00:00Z"))
    #expect(week.upperBound == month.upperBound)
}
