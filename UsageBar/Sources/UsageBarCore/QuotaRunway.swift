import Foundation

public struct QuotaRunway: Sendable {
    public struct Entry: Sendable {
        public var startsAt: Date?
        public var exhaustsAt: Date?
        public var refills = 0
        public var interrupted = false
        public var coveredThrough: Date?
    }

    public let entries: [String: Entry]
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
    /// A conditional priority schedule, not an inference about which account has live sessions.
    /// Plan weights normalize both historical consumption and future available capacity.
    public func runway(
        _ readings: [CodexReading],
        now: Date,
        freshness: TimeInterval = 600,
        calendar: Calendar = .current) -> QuotaRunway
    {
        func unavailable(_ reason: String) -> QuotaRunway {
            QuotaRunway(entries: [:], activeDays: 0, dailyConsumption: nil, explanation: reason)
        }
        guard !readings.isEmpty, Set(readings.map(\.id)).count == readings.count,
              readings.allSatisfy({
                  $0.error == nil && $0.updated
                      .map { now.timeIntervalSince($0) >= 0 && now.timeIntervalSince($0) <= freshness } == true
              }) else { return unavailable("Fresh readings are needed for every account in the queue.") }
        let main = readings.map { $0.snapshot?.windows.filter { $0.lane == nil } ?? [] }
        let optionalWeights = readings.map { CodexPlanCapacity.weight($0.snapshot?.plan) }
        guard optionalWeights.allSatisfy({ $0 != nil }) else {
            return unavailable("A quota-capacity weight is unavailable for one of the reported plans.")
        }
        let weights = optionalWeights.compactMap(\.self)
        guard main.allSatisfy({ $0.count == 1 }), let first = main.first?.first,
              first.periodSeconds > 0,
              main.allSatisfy({ $0[0].periodSeconds == first.periodSeconds && $0[0].resetsAt > now })
        else {
            return unavailable(
                "An ordered runway needs one comparable main allowance per account, with matching durations.")
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
        let rate = daily / 86400
        let windows = main.map { $0[0] }
        // Only one reported reset per allowance is known. Stop before another could occur.
        let horizon = min(now.addingTimeInterval(30 * 86400), windows.map {
            $0.resetsAt.addingTimeInterval($0.periodSeconds)
        }.min() ?? now)
        let simulated = Self.simulate(windows: windows, weights: weights, now: now, horizon: horizon, rate: rate)
        let order = readings.map(\.label).joined(separator: " → ")
        let explanation = "Order: \(order). Uses the first available account; a refill can return an earlier account to the front. "
            + "30-day history: \(totals.count) active dates, " + String(format: "%.1f", daily)
            + " Pro-20x-equivalent percentage points/day. Each date counts once. Today and idle dates are excluded. "
            + "Uses nominal plan weights: Pro 20x = 1, Pro 5x = 0.25, Plus = 0.05; assumes active days ahead. "
            + "Reported resets refill to 100%; unreported/banked resets are not predicted. "
            + "Schedule stops before a second unreported refill, at \(horizon.formatted()). "
            + "Usage outside the queue reduces the next refreshed balance. Missing historical usage can make estimates optimistic. "
            + "This schedule does not select or detect the active account. Model-specific fallback capacity is excluded."
        return QuotaRunway(
            entries: Dictionary(uniqueKeysWithValues: zip(readings.map(\.id), simulated)),
            activeDays: totals.count,
            dailyConsumption: daily,
            explanation: explanation)
    }

    private static func simulate(
        windows: [QuotaWindow],
        weights: [Double],
        now: Date,
        horizon: Date,
        rate: Double) -> [QuotaRunway.Entry]
    {
        var remaining = zip(windows, weights).map { $0.remainingPercent * $1 }
        var resetPending = windows.map { Optional($0.resetsAt) }
        var entries = windows.map { _ in QuotaRunway.Entry() }
        var cursor = now
        var previousActive: Int?
        // At most one reset and two depletions per account, plus idle intervals.
        for _ in 0..<(windows.count * 4 + 2) {
            guard cursor < horizon else { break }
            for index in windows.indices where resetPending[index].map({ $0 <= cursor }) == true {
                remaining[index] = 100 * weights[index]
                resetPending[index] = nil
                if entries[index].exhaustsAt == nil { entries[index].refills += 1 }
            }
            let nextReset = resetPending.compactMap(\.self).min() ?? horizon
            guard let active = remaining.firstIndex(where: { $0 > 0.000_001 }) else {
                // No capacity right now; future use has to wait for a known reset.
                guard nextReset < horizon else { break }
                cursor = nextReset
                previousActive = nil
                continue
            }
            if let previousActive, previousActive != active, entries[previousActive].exhaustsAt == nil {
                entries[previousActive].interrupted = true
            }
            previousActive = active
            if entries[active].startsAt == nil { entries[active].startsAt = cursor }
            let depletion = cursor.addingTimeInterval(remaining[active] / rate)
            let next = min(depletion, nextReset, horizon)
            remaining[active] = max(0, remaining[active] - next.timeIntervalSince(cursor) * rate)
            // At an exact reset boundary, replenishment wins: there is no period of exhaustion.
            let refillsAtDepletion = resetPending[active].map { $0 <= depletion } ?? false
            if !refillsAtDepletion, depletion < horizon, depletion <= next, entries[active].exhaustsAt == nil {
                entries[active].exhaustsAt = depletion
            }
            cursor = next
            if cursor == horizon, entries[active].exhaustsAt == nil { entries[active].coveredThrough = horizon }
        }
        return entries
    }
}
