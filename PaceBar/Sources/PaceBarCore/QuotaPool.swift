import Foundation

/// Combined tracked Codex capacity, assuming parallel use and earliest-reset-first routing.
public struct QuotaPool: Sendable {
    /// Plan-weighted share of the pool still available; `nil` without fresh, weighted readings.
    public let remainingPercent: Double?
    /// First moment the whole pool is empty at the observed pace.
    public let exhaustsAt: Date?
    /// The pool lasts at least this long; set when it does not run out before the forecast horizon.
    public let coveredThrough: Date?
    /// Share of total pool capacity that resets before it can be spent at the observed pace.
    public let expiringPercent: Double
    /// Account-percentage points expiring unused, by account id.
    public let expiring: [String: Double]
    public let activeDays: Int
    public let dailyConsumption: Double?
    public let explanation: String
}

/// Nominal tier weights, expressed relative to Pro 20x. Provider labels follow
/// CodexBar's CodexPlanFormatting; tier ratios: https://learn.chatgpt.com/docs/pricing
public enum CodexPlanCapacity {
    public static func weight(_ plan: String?) -> Double? {
        switch plan?.lowercased() {
        case "pro": 1
        case "prolite", "pro_lite", "pro-lite", "pro lite": 0.25
        case "plus": 0.05
        default: nil
        }
    }
}

extension QuotaForecast {
    /// Plan weights normalize both historical consumption and future available capacity.
    public func pool(
        _ readings: [CodexReading],
        now: Date,
        freshness: TimeInterval = 600,
        calendar: Calendar = .current) -> QuotaPool
    {
        var remaining: Double?
        func unavailable(_ reason: String) -> QuotaPool {
            QuotaPool(
                remainingPercent: remaining, exhaustsAt: nil, coveredThrough: nil, expiringPercent: 0, expiring: [:],
                activeDays: 0, dailyConsumption: nil, explanation: reason)
        }
        guard !readings.isEmpty, Set(readings.map(\.id)).count == readings.count,
              readings.allSatisfy({
                  $0.error == nil && $0.updated
                      .map { now.timeIntervalSince($0) >= 0 && now.timeIntervalSince($0) <= freshness } == true
              }) else { return unavailable("Fresh readings are needed for every account in the pool.") }
        let main = readings.map { $0.snapshot?.windows.filter { $0.lane == nil } ?? [] }
        let optionalWeights = readings.map { CodexPlanCapacity.weight($0.snapshot?.plan) }
        guard optionalWeights.allSatisfy({ $0 != nil }), main.allSatisfy({ !$0.isEmpty }) else {
            return unavailable("A quota-capacity weight is unavailable for one of the reported plans.")
        }
        let weights = optionalWeights.compactMap(\.self)
        let capacity = weights.reduce(0, +) * 100
        remaining = zip(main, weights).map { windows, weight in
            (windows.map(\.remainingPercent).min() ?? 0) * weight
        }.reduce(0, +) / capacity * 100
        guard main.allSatisfy({ $0.count == 1 }), let first = main.first?.first,
              first.periodSeconds > 0,
              main.allSatisfy({ $0[0].periodSeconds == first.periodSeconds && $0[0].resetsAt > now })
        else {
            return unavailable("A pooled forecast needs one comparable main allowance per account.")
        }
        var totals: [Date: Double] = [:]
        for (index, reading) in readings.enumerated() {
            for (date, consumed) in self.activeDayTotals(
                account: reading.id,
                window: main[index][0],
                now: now,
                calendar: calendar)
            {
                totals[date, default: 0] += consumed * weights[index]
            }
        }
        guard totals.count >= 2
        else { return unavailable("Needs two completed days with observed activity across the accounts.") }
        let daily = totals.values.reduce(0, +) / Double(totals.count)
        guard daily.isFinite, daily > 0 else { return unavailable("No usable historical consumption rate.") }
        let windows = main.map { $0[0] }
        // Only one reported reset per allowance is known. Stop before another could occur.
        let horizon = min(now.addingTimeInterval(30 * 86400), windows.map {
            $0.resetsAt.addingTimeInterval($0.periodSeconds)
        }.min() ?? now)
        let result = Self.simulate(
            windows: windows, weights: weights, now: now, horizon: horizon, rate: daily / 86400)
        let expiring = Dictionary(uniqueKeysWithValues: zip(
            readings.map(\.id),
            zip(result.wasted, weights).map { $0 / $1 }))
        let explanation = "Assumes tracked Codex accounts are used in parallel with earliest-reset-first routing. "
            + "Pace Bar enrollment does not change OMP routing. "
            + "30-day history: \(totals.count) active dates, " + String(format: "%.1f", daily)
            + " Pro-20x-equivalent percentage points/day across tracked Codex accounts. Each date counts once. "
            + "Today and idle dates are excluded. "
            + "Uses nominal plan weights: Pro 20x = 1, Pro 5x = 0.25, Plus = 0.05; assumes active days ahead. "
            + "Reported resets refill to 100%; unreported/banked resets are not predicted. "
            + "Forecast stops before a second unreported refill, at \(horizon.formatted()). "
            + "Missing historical usage can make estimates optimistic. Model-specific fallback capacity is excluded."
        return QuotaPool(
            remainingPercent: remaining,
            exhaustsAt: result.exhaustsAt,
            coveredThrough: result.exhaustsAt == nil ? horizon : nil,
            expiringPercent: result.wasted.reduce(0, +) / capacity * 100,
            expiring: expiring,
            activeDays: totals.count,
            dailyConsumption: daily,
            explanation: explanation)
    }

    /// Spends earliest-resetting capacity first, the order that strands the least quota at a reset.
    private static func simulate(
        windows: [QuotaWindow],
        weights: [Double],
        now: Date,
        horizon: Date,
        rate: Double) -> (exhaustsAt: Date?, wasted: [Double])
    {
        var remaining = zip(windows, weights).map { $0.remainingPercent * $1 }
        var resetPending = windows.map { Optional($0.resetsAt) }
        let nextKnownReset = windows.map { $0.resetsAt.addingTimeInterval($0.periodSeconds) }
        var wasted = windows.map { _ in 0.0 }
        var exhaustsAt: Date?
        var cursor = now
        // Each account resets at most once and depletes at most twice before the horizon.
        for _ in 0..<(windows.count * 4 + 2) {
            guard cursor < horizon else { break }
            for index in windows.indices where resetPending[index].map({ $0 <= cursor }) == true {
                wasted[index] += remaining[index]
                remaining[index] = 100 * weights[index]
                resetPending[index] = nil
            }
            let nextReset = resetPending.compactMap(\.self).min() ?? horizon
            let active = windows.indices.filter { remaining[$0] > 0.000_001 }
                .min { (resetPending[$0] ?? nextKnownReset[$0]) < (resetPending[$1] ?? nextKnownReset[$1]) }
            guard let active else {
                if exhaustsAt == nil { exhaustsAt = cursor }
                guard nextReset < horizon else { break }
                cursor = nextReset
                continue
            }
            let depletion = cursor.addingTimeInterval(remaining[active] / rate)
            let next = min(depletion, nextReset, horizon)
            remaining[active] = max(0, remaining[active] - next.timeIntervalSince(cursor) * rate)
            cursor = next
        }
        return (exhaustsAt, wasted)
    }
}
