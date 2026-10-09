import Foundation
import Testing
@testable import PaceBarCore

private let poolNow = Date(timeIntervalSince1970: 1_800_000_000)
private let poolDay: Double = 86400
private var poolCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private let poolMonth: Double = 2_592_000

private func poolWindow(
    remaining: Double = 100,
    reset: Double = 7,
    lane: String? = nil,
    period: Double = 604_800) -> QuotaWindow
{
    QuotaWindow(
        id: lane ?? "main",
        label: "Weekly",
        periodSeconds: period,
        lane: lane,
        usedPercent: 100 - remaining,
        resetsAt: poolNow.addingTimeInterval(reset * poolDay))
}

private func poolAccount(
    _ id: String,
    remaining: Double = 100,
    reset: Double = 7,
    plan: String = "pro",
    period: Double = 604_800) -> CodexReading
{
    CodexReading(
        id: id,
        label: id,
        snapshot: CodexSnapshot(
            windows: [poolWindow(remaining: remaining, reset: reset, period: period)],
            plan: plan),
        updated: poolNow,
        error: nil)
}

private func poolActivity(
    _ forecast: inout QuotaForecast,
    account: String,
    amount: Double,
    ago: Int,
    lane: String? = nil,
    period: Double = 604_800)
{
    let start = poolCalendar.startOfDay(for: poolNow).addingTimeInterval(-Double(ago) * poolDay + 3600)
    for (offset, used) in [(0.0, 0.0), (3600.0, amount)] {
        let quota = QuotaWindow(
            id: lane ?? "main",
            label: "Weekly",
            periodSeconds: period,
            lane: lane,
            usedPercent: used,
            resetsAt: start.addingTimeInterval(period))
        forecast.record(
            account: account,
            windows: [quota],
            at: start.addingTimeInterval(offset),
            calendar: poolCalendar)
    }
}

private func poolHistory(rate: Double) -> QuotaForecast {
    var forecast = QuotaForecast()
    for ago in [2, 1] {
        poolActivity(&forecast, account: "a", amount: rate, ago: ago)
    }
    return forecast
}

@Test func `Removed enrollments contribute neither capacity nor historical rate and missing enabled accounts block the pool`() throws {
    var config = Configuration()
    var forecast = QuotaForecast()
    for number in 1...4 {
        try config.enroll(AccountCandidate(
            provider: .codex, providerAccountID: "\(number)", label: "Codex \(number)",
            source: .codexFiles(paths: ["/test/\(number)/auth.json"], managedHome: nil)))
        for ago in [2, 1] {
            poolActivity(&forecast, account: "\(number)", amount: Double(number * 10), ago: ago)
        }
    }
    config.accounts[2].removed = true
    config.accounts[3].removed = true
    let active = config.activeAccounts(.codex)
    let readings = active.map { poolAccount($0.readingID, remaining: $0.slot == 0 ? 50 : 100) }
    let pool = forecast.pool(readings, now: poolNow, calendar: poolCalendar)
    #expect(pool.remainingPercent == 75)
    #expect(pool.dailyConsumption == 30)
    #expect(active.map(\.label) == ["Codex 1", "Codex 2"])
    var missing = readings
    missing[1].error = "unavailable"
    #expect(forecast.pool(missing, now: poolNow, calendar: poolCalendar).remainingPercent == nil)
    config.accounts[1].removed = true
    #expect(forecast.pool([readings[0]], now: poolNow, calendar: poolCalendar).remainingPercent == 50)
}

@Test func `Pooled pace sums each calendar date once and empties the pool as a whole`() {
    var forecast = QuotaForecast()
    for ago in [2, 1] {
        poolActivity(&forecast, account: "a", amount: 20, ago: ago)
        poolActivity(&forecast, account: "b", amount: 30, ago: ago)
    }
    poolActivity(&forecast, account: "b", amount: 100, ago: 0) // Today must not dominate.
    let pool = forecast.pool([poolAccount("a", remaining: 50), poolAccount("b")], now: poolNow, calendar: poolCalendar)
    #expect(pool.activeDays == 2)
    #expect(pool.dailyConsumption == 50)
    #expect(pool.remainingPercent == 75)
    #expect(pool.exhaustsAt == poolNow.addingTimeInterval(3 * poolDay))
    #expect(pool.expiringPercent == 0)
}

@Test func `Earliest resetting quota is spent first so a refill extends the pool without waste`() {
    let pool = poolHistory(rate: 50).pool(
        [poolAccount("a"), poolAccount("b", remaining: 50, reset: 1)],
        now: poolNow,
        calendar: poolCalendar)
    // b's 50 is spent before its reset, then b refills: 100 + 50 + 100 at 50 per day.
    #expect(pool.exhaustsAt == poolNow.addingTimeInterval(5 * poolDay))
    #expect(pool.expiring["b"] == 0)
}

@Test func `Slow use reports quota that resets unused and stops before unreported refills`() {
    let pool = poolHistory(rate: 10).pool(
        [poolAccount("a", reset: 1), poolAccount("b")],
        now: poolNow,
        calendar: poolCalendar)
    #expect(pool.exhaustsAt == nil)
    #expect(pool.coveredThrough == poolNow.addingTimeInterval(8 * poolDay))
    #expect(pool.expiring["a"] == 90)
    // After a's refill, b's earlier reset makes it next; 60 of its 100 points are used by day 7.
    #expect(abs((pool.expiring["b"] ?? 0) - 40) < 1e-6)
    #expect(abs(pool.expiringPercent - 65) < 1e-6)
}

@Test func `An empty pool reports exhaustion now while waiting for a known refill`() {
    let pool = poolHistory(rate: 50).pool(
        [poolAccount("a", remaining: 0, reset: 1), poolAccount("b", remaining: 0, reset: 2)],
        now: poolNow,
        calendar: poolCalendar)
    #expect(pool.exhaustsAt == poolNow)
    #expect(pool.remainingPercent == 0)
}

@Test func `Mixed Pro tiers normalize daily consumption remaining balance and waste`() {
    var forecast = QuotaForecast()
    for ago in [2, 1] {
        poolActivity(&forecast, account: "a", amount: 20, ago: ago)
        poolActivity(&forecast, account: "b", amount: 40, ago: ago)
    }
    let pool = forecast.pool(
        [poolAccount("a", remaining: 60), poolAccount("b", plan: "prolite")],
        now: poolNow,
        calendar: poolCalendar)
    #expect(pool.dailyConsumption == 30) // 20 Pro-20x points + 40 × 0.25 Pro-5x points.
    #expect(pool.remainingPercent == 68) // (60 + 25) of 125 weighted points.
    #expect(pool.exhaustsAt == poolNow.addingTimeInterval(85.0 / 30 * poolDay))
}

@Test func `A Free account's 30-day allowance joins the pool at its nominal weight and is spent last`() {
    var forecast = QuotaForecast()
    for ago in [2, 1] {
        poolActivity(&forecast, account: "a", amount: 20, ago: ago)
        poolActivity(&forecast, account: "b", amount: 50, ago: ago, period: poolMonth)
    }
    let free = poolAccount("b", remaining: 50, reset: 20, plan: "free", period: poolMonth)
    let pool = forecast.pool([poolAccount("a", remaining: 30, reset: 1), free], now: poolNow, calendar: poolCalendar)
    #expect(abs((pool.dailyConsumption ?? 0) - 20.5) < 1e-9) // 20 Pro-20x points + 50 × 0.01 Free points.
    #expect(abs((pool.remainingPercent ?? 0) - 30.5 / 101 * 100) < 1e-9)
    // The Pro week spends 20.5 before its reset and strands 9.5; the refilled week still resets before the
    // Free month, so Free's 0.5 Pro-20x points go last.
    #expect(abs((pool.expiring["a"] ?? 0) - 9.5) < 1e-6)
    #expect(pool.expiring["b"] == 0)
    #expect(pool.exhaustsAt.map { abs($0.timeIntervalSince(poolNow) - (1 + 100.5 / 20.5) * poolDay) < 1 } == true)
}

@Test func `An allowance of a different length than its plan's keeps the balance but not the forecast`() {
    let forecast = poolHistory(rate: 20)
    let weeklyFree = poolAccount("b", plan: "free")
    let monthlyPro = poolAccount("b", period: poolMonth)
    for mismatched in [weeklyFree, monthlyPro] {
        let pool = forecast.pool([poolAccount("a"), mismatched], now: poolNow, calendar: poolCalendar)
        #expect(pool.exhaustsAt == nil && pool.coveredThrough == nil)
        #expect(pool.remainingPercent == 100)
    }
}

@Test func `Reserve consumption never inflates the main pooled pace`() {
    var forecast = poolHistory(rate: 20)
    for ago in [2, 1] {
        poolActivity(&forecast, account: "a", amount: 100, ago: ago, lane: "reserve")
    }
    #expect(forecast.pool([poolAccount("a")], now: poolNow, calendar: poolCalendar).dailyConsumption == 20)
}

@Test func `Stale unknown and layered quotas cannot produce an optimistic forecast`() {
    let forecast = poolHistory(rate: 20)
    var stale = poolAccount("b")
    stale.updated = poolNow.addingTimeInterval(-601)
    let unknown = poolAccount("b", plan: "enterprise")
    var layered = poolAccount("b")
    layered.snapshot = CodexSnapshot(windows: [poolWindow(), poolWindow(remaining: 40)], plan: "pro")
    for invalid in [stale, unknown, layered] {
        let pool = forecast.pool([poolAccount("a"), invalid], now: poolNow, calendar: poolCalendar)
        #expect(pool.exhaustsAt == nil && pool.coveredThrough == nil)
    }
    // A layered account still has a known balance: its tightest allowance.
    #expect(forecast.pool([poolAccount("a"), layered], now: poolNow, calendar: poolCalendar).remainingPercent == 70)
    #expect(forecast.pool([poolAccount("a"), stale], now: poolNow, calendar: poolCalendar).remainingPercent == nil)
}
