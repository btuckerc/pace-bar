import Foundation
import Testing
@testable import UsageBarCore

private var backfillCalendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(secondsFromGMT: 0)!
    return value
}

private let backfillNow = Date(timeIntervalSince1970: 1_800_000_000)
private let backfillWindow = QuotaWindow(
    id: "Codex-primary_window", label: "Weekly", periodSeconds: 604_800, lane: nil,
    usedPercent: 80, resetsAt: backfillNow.addingTimeInterval(604_800))

private func backfillReadings(plan: String = "pro") -> [CodexReading] {
    [CodexReading(
        id: "a",
        label: "primary",
        snapshot: CodexSnapshot(windows: [backfillWindow], plan: plan),
        updated: backfillNow,
        error: nil)]
}

private func backfillData() throws -> Data {
    var samples: [[String: Any]] = []
    for ago in [2, 1] {
        let start = backfillCalendar.startOfDay(for: backfillNow).addingTimeInterval(-Double(ago) * 86400 + 3600)
        for (seconds, used) in [(0.0, 0.0), (3600.0, 20.0)] {
            samples.append([
                "account": "a",
                "date": start.timeIntervalSince1970 + seconds,
                "used": used,
                "period": 604_800,
                "reset": start.timeIntervalSince1970 + 604_800,
                "plan": "pro",
            ])
        }
    }
    return try JSONSerialization.data(withJSONObject: Array(samples.reversed()))
}

@Test func `Backfill sorts snapshots matches quota duration and immediately enables history`() throws {
    let forecast = try QuotaBackfill.merge(
        backfillData(),
        into: QuotaForecast(),
        readings: backfillReadings(),
        now: backfillNow,
        calendar: backfillCalendar)
    let projection = forecast.project(
        account: "a",
        window: backfillWindow,
        now: backfillNow,
        calendar: backfillCalendar)
    #expect(projection.method.contains("2 active days"))
    #expect(projection.exhaustion == backfillNow.addingTimeInterval(86400))
}

@Test func `Repeated overlapping backfills do not add daily totals twice`() throws {
    let data = try backfillData()
    let first = try QuotaBackfill.merge(
        data,
        into: QuotaForecast(),
        readings: backfillReadings(),
        now: backfillNow,
        calendar: backfillCalendar)
    let second = try QuotaBackfill.merge(
        data,
        into: first,
        readings: backfillReadings(),
        now: backfillNow,
        calendar: backfillCalendar)
    #expect(second.project(account: "a", window: backfillWindow, now: backfillNow, calendar: backfillCalendar)
        .exhaustion == backfillNow.addingTimeInterval(86400))
}

@Test func `Backfill refuses mismatched plans and unidentified accounts`() throws {
    for readings in [backfillReadings(plan: "plus"), []] {
        let forecast = try QuotaBackfill.merge(
            backfillData(),
            into: QuotaForecast(),
            readings: readings,
            now: backfillNow,
            calendar: backfillCalendar)
        #expect(forecast.project(account: "a", window: backfillWindow, now: backfillNow).method == "Learning history")
    }
}

@Test func `Small reset timestamp jitter does not erase observed consumption`() {
    var forecast = QuotaForecast()
    for ago in [2, 1] {
        let start = backfillCalendar.startOfDay(for: backfillNow).addingTimeInterval(-Double(ago) * 86400 + 3600)
        for (offset, used) in [(0.0, 0.0), (3600.0, 20.0)] {
            let quota = QuotaWindow(
                id: backfillWindow.id,
                label: "Weekly",
                periodSeconds: 604_800,
                lane: nil,
                usedPercent: used,
                resetsAt: start.addingTimeInterval(604_800 + offset / 3600))
            forecast.record(
                account: "a",
                windows: [quota],
                at: start.addingTimeInterval(offset),
                calendar: backfillCalendar)
        }
    }
    #expect(forecast.project(account: "a", window: backfillWindow, now: backfillNow, calendar: backfillCalendar)
        .exhaustion == backfillNow.addingTimeInterval(86400))
}

@Test func `Import preserves the newer live baseline when adding older days`() throws {
    var live = QuotaForecast()
    live.record(account: "a", windows: [backfillWindow], at: backfillNow, calendar: backfillCalendar)
    var merged = try QuotaBackfill.merge(
        backfillData(),
        into: live,
        readings: backfillReadings(),
        now: backfillNow,
        calendar: backfillCalendar)
    let changed = QuotaWindow(
        id: backfillWindow.id,
        label: "Weekly",
        periodSeconds: 604_800,
        lane: nil,
        usedPercent: 85,
        resetsAt: backfillWindow.resetsAt)
    merged.record(account: "a", windows: [changed], at: backfillNow.addingTimeInterval(60), calendar: backfillCalendar)
    let tomorrow = backfillNow.addingTimeInterval(86400)
    let projection = merged.project(account: "a", window: changed, now: tomorrow, calendar: backfillCalendar)
    #expect(projection.method.contains("3 active days"))
    #expect(projection.method.contains("15.0 percentage points/day"))
}
