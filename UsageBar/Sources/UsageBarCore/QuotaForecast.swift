import Foundation

public struct QuotaProjection: Sendable {
    public let exhaustion: Date?
    public let method: String
}

public struct QuotaForecast: Sendable {
    private struct Point: Sendable {
        let date: Date
        let used: Double
        let reset: Date
    }

    private var history: [String: [Point]] = [:]
    public init() {}

    private func key(account: String, window: QuotaWindow) -> String { account + "\u{0}" + window.id }

    public mutating func record(account: String, windows: [QuotaWindow], at date: Date) {
        // Only current data is retained, bounded to six hours / 73 points per lane.
        self.history = self.history.filter { date.timeIntervalSince($0.value.last?.date ?? .distantPast) <= 21600 }
        for window in windows.prefix(16) {
            let key = self.key(account: account, window: window)
            var points = self.history[key] ?? []
            if let last = points.last,
               last.reset != window.resetsAt || window.usedPercent < last.used || date <= last.date
            { points = [] }
            points.removeAll { date.timeIntervalSince($0.date) > 21600 }
            points.append(Point(date: date, used: min(100, window.usedPercent), reset: window.resetsAt))
            self.history[key] = Array(points.suffix(73))
        }
        if self.history.count > 128 { self.history = [:] }
    }

    public func project(account: String, window: QuotaWindow, now: Date) -> QuotaProjection {
        guard window.resetsAt > now else { return QuotaProjection(exhaustion: nil, method: "Awaiting reset refresh") }
        if window.remainingPercent == 0 { return QuotaProjection(exhaustion: now, method: "Already capped") }
        if window.usedPercent == 0 {
            return QuotaProjection(exhaustion: nil, method: "No consumption observed")
        }
        let points = self.history[self.key(account: account, window: window)] ?? []
        var rate: Double?
        var method = "Current-window average"
        if let first = points.first, let last = points.last,
           last.reset == window.resetsAt, last.used == min(100, window.usedPercent),
           now.timeIntervalSince(last.date) <= 1800,
           last.date.timeIntervalSince(first.date) >= 1800,
           last.used - first.used >= 1
        {
            rate = (last.used - first.used) / last.date.timeIntervalSince(first.date)
            method = "Recent observed average (up to six hours)"
        }
        if rate == nil {
            let elapsed = window.periodSeconds - window.resetsAt.timeIntervalSince(now)
            guard elapsed >= 900, elapsed <= window.periodSeconds else {
                return QuotaProjection(exhaustion: nil, method: "Too early in this window")
            }
            rate = min(100, window.usedPercent) / elapsed
        }
        guard let rate, rate > 0 else { return QuotaProjection(exhaustion: nil, method: "No consumption observed") }
        let date = now.addingTimeInterval(window.remainingPercent / rate)
        return QuotaProjection(exhaustion: date < window.resetsAt ? date : nil, method: method)
    }

    public struct Summary: Sendable {
        public enum Outcome: Sendable { case exhausted(Date), resetFirst(Date), nextReset(Date), insufficient }
        public let outcome: Outcome
        public let details: String
    }

    public func summarize(_ accounts: [CodexReading], now: Date, freshness: TimeInterval = 600) -> Summary {
        let explanation = "All currently reported quotas, including reserve, exhausted simultaneously. "
            + "Assumes unchanged consumption on each account/lane; switching accounts or models changes the forecast. "
            + "Estimates stop at the earliest reported reset, with no assumed future refill schedule."
        guard !accounts.isEmpty,
              accounts.allSatisfy({ account in
                  account.error == nil && account.snapshot?.windows.isEmpty == false
                      && account.updated
                      .map { now.timeIntervalSince($0) >= 0 && now.timeIntervalSince($0) <= freshness } == true
              })
        else { return Summary(outcome: .insufficient, details: "Fresh readings needed for every account.") }
        var earliestReset = Date.distantFuture
        var latestExhaustion = now
        var allExhaust = true
        var insufficient = false
        var lines: [String] = []
        for account in accounts {
            for window in account.snapshot?.windows ?? [] {
                earliestReset = min(earliestReset, window.resetsAt)
                let projection = self.project(account: account.id, window: window, now: now)
                if let date = projection.exhaustion {
                    latestExhaustion = max(latestExhaustion, date)
                } else {
                    allExhaust = false
                    insufficient = insufficient || projection.method == "Too early in this window"
                        || projection.method == "Awaiting reset refresh"
                }
                let estimate: String = if let exhaustion = projection.exhaustion {
                    exhaustion.formatted(date: .abbreviated, time: .shortened)
                } else if projection.method == "Too early in this window" || projection
                    .method == "Awaiting reset refresh"
                {
                    "Not enough timing data"
                } else {
                    "No cap projected before its reset"
                }
                lines.append("\(account.label) · \(window.compactLabel): \(estimate) (\(projection.method))")
            }
        }
        let outcome: Summary.Outcome = if earliestReset <= now {
            .insufficient
        } else if insufficient {
            .nextReset(earliestReset)
        } else if allExhaust, latestExhaustion < earliestReset {
            .exhausted(latestExhaustion)
        } else {
            .resetFirst(earliestReset)
        }
        return Summary(outcome: outcome, details: explanation + "\n\n" + lines.joined(separator: "\n"))
    }
}
