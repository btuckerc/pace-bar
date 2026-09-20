import Foundation
import Testing
@testable import UsageBarCore

private let forecastNow = Date(timeIntervalSince1970: 1_800_000_000)

private func window(_ used: Double, reset: Double = 3600, lane: String? = nil) -> QuotaWindow {
    QuotaWindow(
        id: lane ?? "base",
        label: lane ?? "Base",
        periodSeconds: 7200,
        lane: lane,
        usedPercent: used,
        resetsAt: forecastNow.addingTimeInterval(reset))
}

private func account(_ id: String, _ windows: [QuotaWindow]) -> CodexReading {
    CodexReading(
        id: id,
        label: id,
        snapshot: CodexSnapshot(windows: windows, plan: "test"),
        updated: forecastNow,
        error: nil)
}

@Test func `Full exhaustion occurs at the last lane only if blocked intervals overlap`() {
    let forecast = QuotaForecast()
    let summary = forecast.summarize([account("a", [window(80)]), account("b", [window(90)])], now: forecastNow)
    guard case let .exhausted(date) = summary.outcome else { Issue.record("Expected exhaustion"); return }
    #expect(abs(date.timeIntervalSince(forecastNow) - 900) < 0.01)
}

@Test func `A refill interrupts exhaustion even if every lane individually runs out`() {
    let forecast = QuotaForecast()
    let summary = forecast.summarize([
        account("a", [window(100, reset: 600)]), account("b", [window(80)]),
    ], now: forecastNow)
    guard case let .resetFirst(date) = summary.outcome else { Issue.record("Expected reset first"); return }
    #expect(date == forecastNow.addingTimeInterval(600))
}

@Test func `Exactly lasting to reset is not classified as exhaustion`() {
    let summary = QuotaForecast().summarize([account("a", [window(50)])], now: forecastNow)
    guard case .resetFirst = summary.outcome else { Issue.record("Should last to reset"); return }
}

@Test func `Reserve remains separate even when main allowances are already capped`() {
    let summary = QuotaForecast().summarize([
        account("a", [window(100), window(0, lane: "reserve")]), account("b", [window(100)]),
    ], now: forecastNow)
    guard case .resetFirst = summary.outcome else { Issue.record("Reserve is still available"); return }
}

@Test func `Recent rates remain isolated across accounts with identical window IDs`() {
    var forecast = QuotaForecast()
    forecast.record(account: "a", windows: [window(60)], at: forecastNow.addingTimeInterval(-1800))
    forecast.record(account: "b", windows: [window(79)], at: forecastNow.addingTimeInterval(-1800))
    forecast.record(account: "a", windows: [window(80)], at: forecastNow)
    forecast.record(account: "b", windows: [window(80)], at: forecastNow)
    let fast = forecast.project(account: "a", window: window(80), now: forecastNow)
    let slow = forecast.project(account: "b", window: window(80), now: forecastNow)
    #expect(fast.exhaustion == forecastNow.addingTimeInterval(1800))
    #expect(slow.exhaustion == nil)
    #expect(fast.method.hasPrefix("Recent"))
}

@Test func `Counter correction and reset changes discard prior consumption rates`() {
    var forecast = QuotaForecast()
    forecast.record(account: "a", windows: [window(40)], at: forecastNow.addingTimeInterval(-1800))
    forecast.record(account: "a", windows: [window(80)], at: forecastNow)
    forecast.record(account: "a", windows: [window(20)], at: forecastNow.addingTimeInterval(300))
    #expect(forecast.project(account: "a", window: window(20), now: forecastNow.addingTimeInterval(300))
        .method == "Current-window average")
    forecast.record(account: "a", windows: [window(30, reset: 4000)], at: forecastNow.addingTimeInterval(600))
    #expect(forecast.project(account: "a", window: window(30, reset: 4000), now: forecastNow.addingTimeInterval(600))
        .method == "Current-window average")
}

@Test func `Stale accounts and early windows do not produce confident forecasts`() {
    var stale = account("a", [window(80)])
    stale.updated = forecastNow.addingTimeInterval(-601)
    guard case .insufficient = QuotaForecast().summarize([stale], now: forecastNow).outcome else {
        Issue.record("Stale data must not forecast"); return
    }
    guard case .insufficient = QuotaForecast().summarize([
        account("a", [window(1, reset: 7100)]),
    ], now: forecastNow).outcome else { Issue.record("Early data must not forecast"); return }
}
