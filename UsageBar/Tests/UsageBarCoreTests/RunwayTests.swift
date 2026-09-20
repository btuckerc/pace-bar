import Foundation
import Testing
@testable import UsageBarCore

private let runwayNow = Date(timeIntervalSince1970: 1_800_000_000)
private let runwayDay: Double = 86400
private var runwayCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private func runwayWindow(remaining: Double = 100, reset: Double = 7, lane: String? = nil) -> QuotaWindow {
    QuotaWindow(
        id: lane ?? "main",
        label: "Weekly",
        periodSeconds: 604_800,
        lane: lane,
        usedPercent: 100 - remaining,
        resetsAt: runwayNow.addingTimeInterval(reset * runwayDay))
}

private func runwayAccount(_ id: String, remaining: Double = 100, reset: Double = 7) -> CodexReading {
    CodexReading(
        id: id,
        label: id,
        snapshot: CodexSnapshot(windows: [runwayWindow(remaining: remaining, reset: reset)], plan: "pro"),
        updated: runwayNow,
        error: nil)
}

private func runwayActivity(
    _ forecast: inout QuotaForecast,
    account: String,
    amount: Double,
    ago: Int,
    lane: String? = nil)
{
    let start = runwayCalendar.startOfDay(for: runwayNow).addingTimeInterval(-Double(ago) * runwayDay + 3600)
    for (offset, used) in [(0.0, 0.0), (3600.0, amount)] {
        let quota = QuotaWindow(
            id: lane ?? "main",
            label: "Weekly",
            periodSeconds: 604_800,
            lane: lane,
            usedPercent: used,
            resetsAt: start.addingTimeInterval(604_800))
        forecast.record(
            account: account,
            windows: [quota],
            at: start.addingTimeInterval(offset),
            calendar: runwayCalendar)
    }
}

private func runwayHistory(rate: Double) -> QuotaForecast {
    var forecast = QuotaForecast()
    for ago in [2, 1] {
        runwayActivity(&forecast, account: "a", amount: rate, ago: ago)
    }
    return forecast
}

@Test func `Pooled pace sums each calendar date once and schedules accounts sequentially`() {
    var forecast = QuotaForecast()
    for ago in [2, 1] {
        runwayActivity(&forecast, account: "a", amount: 20, ago: ago)
        runwayActivity(&forecast, account: "b", amount: 30, ago: ago)
    }
    runwayActivity(&forecast, account: "b", amount: 100, ago: 0) // Today must not dominate.
    let result = forecast.runway(
        [runwayAccount("a", remaining: 50), runwayAccount("b")],
        now: runwayNow,
        calendar: runwayCalendar)
    #expect(result.activeDays == 2)
    #expect(result.dailyConsumption == 50)
    #expect(result.entries["a"]?.startsAt == runwayNow)
    #expect(result.entries["a"]?.exhaustsAt == runwayNow.addingTimeInterval(runwayDay))
    #expect(result.entries["b"]?.startsAt == runwayNow.addingTimeInterval(runwayDay))
    #expect(result.entries["b"]?.exhaustsAt == runwayNow.addingTimeInterval(3 * runwayDay))
}

@Test func `Early spending on a queued account shortens its turn without moving the first account`() {
    let forecast = runwayHistory(rate: 50)
    let full = forecast.runway(
        [runwayAccount("a", remaining: 50), runwayAccount("b")],
        now: runwayNow,
        calendar: runwayCalendar)
    let reduced = forecast.runway(
        [runwayAccount("a", remaining: 50), runwayAccount("b", remaining: 50)],
        now: runwayNow,
        calendar: runwayCalendar)
    #expect(full.entries["a"]?.exhaustsAt == reduced.entries["a"]?.exhaustsAt)
    #expect(reduced.entries["b"]?.exhaustsAt == runwayNow.addingTimeInterval(2 * runwayDay))
}

@Test func `An empty account refilling before its turn gets a full future runway`() {
    let result = runwayHistory(rate: 50).runway(
        [runwayAccount("a"), runwayAccount("b", remaining: 0, reset: 1)],
        now: runwayNow,
        calendar: runwayCalendar)
    #expect(result.entries["b"]?.startsAt == runwayNow.addingTimeInterval(2 * runwayDay))
    #expect(result.entries["b"]?.exhaustsAt == runwayNow.addingTimeInterval(4 * runwayDay))
    #expect(result.entries["b"]?.refills == 1)
}

@Test func `An earlier account refill interrupts and extends a later accounts turn`() {
    let result = runwayHistory(rate: 100).runway(
        [runwayAccount("a", remaining: 20, reset: 0.5), runwayAccount("b")],
        now: runwayNow,
        calendar: runwayCalendar)
    #expect(result.entries["a"]?.exhaustsAt == runwayNow.addingTimeInterval(0.2 * runwayDay))
    #expect(result.entries["b"]?.startsAt == runwayNow.addingTimeInterval(0.2 * runwayDay))
    #expect(result.entries["b"]?.exhaustsAt == runwayNow.addingTimeInterval(2.2 * runwayDay))
    #expect(result.entries["b"]?.interrupted == true)
}

@Test func `An exact own reset prevents depletion while another accounts reset does not`() {
    let forecast = runwayHistory(rate: 50)
    let own = forecast.runway(
        [runwayAccount("a", remaining: 50, reset: 1), runwayAccount("b")],
        now: runwayNow,
        calendar: runwayCalendar)
    #expect(own.entries["a"]?.exhaustsAt == runwayNow.addingTimeInterval(3 * runwayDay))
    let other = forecast.runway(
        [runwayAccount("a", remaining: 50), runwayAccount("b", reset: 1)],
        now: runwayNow,
        calendar: runwayCalendar)
    #expect(other.entries["a"]?.exhaustsAt == runwayNow.addingTimeInterval(runwayDay))
}

@Test func `Slow use is bounded before unreported recurring resets instead of claiming infinite capacity`() {
    let result = runwayHistory(rate: 10).runway(
        [runwayAccount("a", reset: 1), runwayAccount("b")],
        now: runwayNow,
        calendar: runwayCalendar)
    #expect(result.entries["a"]?.exhaustsAt == nil)
    #expect(result.entries["a"]?.coveredThrough == runwayNow.addingTimeInterval(8 * runwayDay))
    #expect(result.entries["b"]?.startsAt == nil)
}

@Test func `Reserve consumption never inflates the main pooled pace`() {
    var forecast = runwayHistory(rate: 20)
    for ago in [2, 1] {
        runwayActivity(&forecast, account: "a", amount: 100, ago: ago, lane: "reserve")
    }
    let result = forecast.runway([runwayAccount("a")], now: runwayNow, calendar: runwayCalendar)
    #expect(result.dailyConsumption == 20)
}

@Test func `Stale incompatible and layered quotas cannot produce an optimistic queue`() {
    let forecast = runwayHistory(rate: 20)
    var stale = runwayAccount("b")
    stale.updated = runwayNow.addingTimeInterval(-601)
    var different = runwayAccount("b")
    different.snapshot = CodexSnapshot(windows: [runwayWindow()], plan: "enterprise")
    var layered = runwayAccount("b")
    layered.snapshot = CodexSnapshot(windows: [runwayWindow(), runwayWindow()], plan: "pro")
    for invalid in [stale, different, layered] {
        #expect(forecast.runway([runwayAccount("a"), invalid], now: runwayNow, calendar: runwayCalendar).entries
            .isEmpty)
    }
}

@Test func `Mixed Pro tiers normalize both daily consumption and remaining balances`() {
    var forecast = QuotaForecast()
    for ago in [2, 1] {
        runwayActivity(&forecast, account: "a", amount: 20, ago: ago)
        runwayActivity(&forecast, account: "b", amount: 40, ago: ago)
    }
    var smaller = runwayAccount("b")
    smaller.snapshot = CodexSnapshot(windows: [runwayWindow()], plan: "prolite")
    let result = forecast.runway([runwayAccount("a", remaining: 60), smaller], now: runwayNow, calendar: runwayCalendar)
    #expect(result.dailyConsumption == 30) // 20 Pro-20x points + 40 × 0.25 Pro-5x points.
    #expect(result.entries["a"]?.exhaustsAt == runwayNow.addingTimeInterval(2 * runwayDay))
    #expect(result.entries["b"]?.exhaustsAt == runwayNow.addingTimeInterval(2 * runwayDay + 72000))
}

@Test func `Refills restore the smaller plans weighted capacity`() {
    var smaller = runwayAccount("b", remaining: 0, reset: 0.5)
    smaller.snapshot = CodexSnapshot(windows: [runwayWindow(remaining: 0, reset: 0.5)], plan: "prolite")
    let result = runwayHistory(rate: 50).runway(
        [runwayAccount("a", remaining: 50), smaller],
        now: runwayNow,
        calendar: runwayCalendar)
    #expect(result.entries["b"]?.exhaustsAt == runwayNow.addingTimeInterval(1.5 * runwayDay))
    #expect(result.entries["b"]?.refills == 1)
}
