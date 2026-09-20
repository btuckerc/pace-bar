import Foundation
import Testing
@testable import UsageBarCore

private let forecastNow = Date(timeIntervalSince1970: 1_800_014_400) // UTC midnight
private let day: TimeInterval = 86400
private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private func window(
    _ used: Double,
    reset: Date = forecastNow.addingTimeInterval(7 * day),
    lane: String = "base",
    period: Double = 604_800) -> QuotaWindow
{
    QuotaWindow(id: lane, label: lane, periodSeconds: period, lane: nil, usedPercent: used, resetsAt: reset)
}

private func activity(
    _ forecast: inout QuotaForecast,
    ago: Int,
    amount: Double,
    account: String = "a",
    lane: String = "base")
{
    let start = utc.startOfDay(for: forecastNow).addingTimeInterval(-Double(ago) * day + 3600)
    let reset = start.addingTimeInterval(7 * day)
    forecast.record(account: account, windows: [window(0, reset: reset, lane: lane)], at: start, calendar: utc)
    forecast.record(
        account: account,
        windows: [window(amount, reset: reset, lane: lane)],
        at: start.addingTimeInterval(3600),
        calendar: utc)
}

@Test func `Mean excludes idle days and todays burst but uses current remaining quota`() throws {
    var forecast = QuotaForecast()
    activity(&forecast, ago: 10, amount: 10)
    activity(&forecast, ago: 2, amount: 30)
    activity(&forecast, ago: 0, amount: 90)
    let now = forecastNow.addingTimeInterval(4 * 3600)
    let projection = forecast.project(account: "a", window: window(60), now: now, calendar: utc)
    #expect(try #require(projection.exhaustion).timeIntervalSince(now) == 2 * day)
    #expect(projection.method.contains("2 active days"))
    #expect(projection.method.contains("20.0 percentage points/day"))
}

@Test func `Only the previous thirty completed days contribute`() throws {
    var forecast = QuotaForecast()
    activity(&forecast, ago: 31, amount: 100)
    activity(&forecast, ago: 30, amount: 10)
    activity(&forecast, ago: 1, amount: 10)
    let projection = forecast.project(account: "a", window: window(90), now: forecastNow, calendar: utc)
    #expect(try #require(projection.exhaustion).timeIntervalSince(forecastNow) == day)
}

@Test func `New cycles use history even with zero current usage`() throws {
    var forecast = QuotaForecast()
    activity(&forecast, ago: 3, amount: 25)
    activity(&forecast, ago: 1, amount: 25)
    #expect(try #require(forecast.project(account: "a", window: window(0), now: forecastNow, calendar: utc)
            .exhaustion).timeIntervalSince(forecastNow) == 4 * day)
}

@Test func `Unknown and single active day histories learn without a current cycle fallback`() {
    var forecast = QuotaForecast()
    #expect(forecast.project(account: "a", window: window(90), now: forecastNow).method == "Learning history")
    activity(&forecast, ago: 1, amount: 90)
    #expect(forecast.project(account: "a", window: window(90), now: forecastNow, calendar: utc)
        .method == "Learning history")
}

@Test func `Accounts reserve and quota durations never borrow another lanes pace`() {
    var forecast = QuotaForecast()
    activity(&forecast, ago: 3, amount: 25)
    activity(&forecast, ago: 1, amount: 25)
    for (account, quota) in [("b", window(90)), ("a", window(90, lane: "reserve")), ("a", window(90, period: 18000))] {
        #expect(forecast.project(account: account, window: quota, now: forecastNow).method == "Learning history")
    }
}

@Test func `A banked reset preserves consumption already recorded that day`() {
    var forecast = QuotaForecast()
    activity(&forecast, ago: 2, amount: 20)
    let start = utc.startOfDay(for: forecastNow).addingTimeInterval(-day + 3600)
    let reset = start.addingTimeInterval(7 * day)
    for (offset, used, deadline) in [
        (0.0, 0.0, reset),
        (3600, 30, reset),
        (7200, 0, reset.addingTimeInterval(7200)),
        (10800, 10, reset.addingTimeInterval(7200)),
    ] {
        forecast.record(
            account: "a",
            windows: [window(used, reset: deadline)],
            at: start.addingTimeInterval(offset),
            calendar: utc)
    }
    #expect(forecast.project(account: "a", window: window(90), now: forecastNow, calendar: utc)
        .method.contains("30.0 percentage points/day"))
}

@Test func `Corrections duplicates and out of order readings cannot double count`() {
    var forecast = QuotaForecast()
    activity(&forecast, ago: 2, amount: 20)
    let start = utc.startOfDay(for: forecastNow).addingTimeInterval(-day + 3600)
    let reset = start.addingTimeInterval(7 * day)
    for (offset, used) in [(0.0, 20.0), (3600, 40), (7200, 30), (10800, 40), (10800, 90), (9000, 90)] {
        forecast.record(
            account: "a",
            windows: [window(used, reset: reset)],
            at: start.addingTimeInterval(offset),
            calendar: utc)
    }
    #expect(forecast.project(account: "a", window: window(90), now: forecastNow, calendar: utc)
        .method.contains("20.0 percentage points/day"))
}

@Test func `Initial readings and gaps across days do not invent daily consumption`() {
    var forecast = QuotaForecast()
    let reset = forecastNow.addingTimeInterval(day)
    for (ago, used) in [(3.0, 40.0), (2, 60), (1, 80)] {
        forecast.record(
            account: "a",
            windows: [window(used, reset: reset)],
            at: forecastNow.addingTimeInterval(-ago * day),
            calendar: utc)
    }
    #expect(forecast.project(account: "a", window: window(90), now: forecastNow, calendar: utc)
        .method == "Learning history")
}

@Test func `Reset boundaries and already capped windows remain factual`() {
    var forecast = QuotaForecast()
    activity(&forecast, ago: 3, amount: 20)
    activity(&forecast, ago: 1, amount: 20)
    let projection = forecast.project(
        account: "a",
        window: window(80, reset: forecastNow.addingTimeInterval(day)),
        now: forecastNow,
        calendar: utc)
    #expect(projection.exhaustion == nil) // Exactly reaches reset, not exhaustion before reset.
    #expect(projection.method.contains("2 active days"))
    #expect(forecast.project(account: "a", window: window(100), now: forecastNow).exhaustion == forecastNow)
    #expect(forecast.project(account: "a", window: window(100, reset: forecastNow), now: forecastNow)
        .method == "Awaiting reset refresh")
}

@Test func `History round trips without raw account identity`() throws {
    var forecast = QuotaForecast()
    activity(&forecast, ago: 2, amount: 20, account: "private-account-identity")
    activity(&forecast, ago: 1, amount: 20, account: "private-account-identity")
    let data = try JSONEncoder().encode(forecast)
    #expect(String(data: data, encoding: .utf8)?.contains("private-account-identity") == false)
    let restored = try JSONDecoder().decode(QuotaForecast.self, from: data)
    #expect(restored.project(account: "private-account-identity", window: window(80), now: forecastNow, calendar: utc)
        .exhaustion == forecastNow.addingTimeInterval(day))
}

@Test func `History persistence survives a fresh store and restricts file permissions`() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("history.json")
    var forecast = QuotaForecast()
    activity(&forecast, ago: 2, amount: 20)
    activity(&forecast, ago: 1, amount: 20)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(forecast).write(to: file)
    let (restored, saved) = await QuotaHistoryStore(file: file).record([])
    #expect(saved)
    #expect(restored.project(account: "a", window: window(80), now: forecastNow, calendar: utc)
        .exhaustion == forecastNow.addingTimeInterval(day))
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    try Data("broken".utf8).write(to: file)
    let (empty, repaired) = await QuotaHistoryStore(file: file).record([])
    #expect(repaired)
    #expect(empty.project(account: "a", window: window(80), now: forecastNow).method == "Learning history")
}
