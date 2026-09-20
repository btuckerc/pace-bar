import CryptoKit
import Foundation

public struct QuotaProjection: Sendable {
    public let exhaustion: Date?
    public let method: String
}

/// Compact, account-isolated observed consumption. No transcripts or credentials.
public struct QuotaForecast: Sendable, Codable {
    private struct Point: Sendable, Codable {
        let date: Date
        let used: Double
        let reset: Date
    }

    private struct Day: Sendable, Codable {
        let date: Date
        var consumed: Double
    }

    private struct Lane: Sendable, Codable {
        var last: Point
        var days: [Day] = []
    }

    private var history: [String: Lane] = [:]
    public init() {}

    private func key(account: String, window: QuotaWindow) -> String {
        let identity = account + "\u{0}" + window.id + "\u{0}" + String(window.periodSeconds)
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public mutating func record(
        account: String,
        windows: [QuotaWindow],
        at date: Date,
        calendar: Calendar = .current)
    {
        let today = calendar.startOfDay(for: date)
        guard let cutoff = calendar.date(byAdding: .day, value: -30, to: today) else { return }
        self.history = self.history.filter { $0.value.last.date >= cutoff }
        for window in windows.prefix(16) {
            guard window.usedPercent.isFinite, window.usedPercent >= 0, window.usedPercent <= 100,
                  window.periodSeconds > 0, window.resetsAt > date else { continue }
            let key = self.key(account: account, window: window)
            let point = Point(date: date, used: window.usedPercent, reset: window.resetsAt)
            guard var lane = self.history[key] else {
                // The initial used percentage may span days: it is a baseline, never new consumption.
                if self.history.count < 128 { self.history[key] = Lane(last: point) }
                continue
            }
            guard date > lane.last.date else { continue }
            let previous = lane.last
            let sameCycle = abs(previous.reset.timeIntervalSince(point.reset)) <= 60
            // Use a high-water mark within a cycle so corrections/rebounds are not counted twice.
            let consumed = sameCycle ? max(0, point.used - previous.used) : 0
            // A cross-midnight gap cannot establish which day consumed the quota. Do not guess.
            if consumed > 0, calendar.isDate(previous.date, inSameDayAs: date) {
                if let index = lane.days.firstIndex(where: { $0.date == today }) {
                    lane.days[index].consumed += consumed
                } else {
                    lane.days.append(Day(date: today, consumed: consumed))
                }
            }
            // A scheduled or banked reset starts a fresh baseline, preserving prior daily totals.
            lane.last = Point(
                date: date,
                used: sameCycle ? max(previous.used, point.used) : point.used,
                reset: point.reset)
            lane.days.removeAll { $0.date < cutoff }
            self.history[key] = lane
        }
    }

    /// Use the larger daily total when sources overlap; re-importing cannot double consumption.
    mutating func mergeHistory(_ imported: QuotaForecast, now: Date, calendar: Calendar) {
        let cutoff = calendar.date(byAdding: .day, value: -30, to: calendar.startOfDay(for: now)) ?? now
        for (key, incoming) in imported.history {
            guard self.history[key] != nil || self.history.count < 128 else { continue }
            var lane = self.history[key] ?? incoming
            for day in incoming.days where day.date >= cutoff {
                if let index = lane.days.firstIndex(where: { $0.date == day.date }) {
                    lane.days[index].consumed = max(lane.days[index].consumed, day.consumed)
                } else {
                    lane.days.append(day)
                }
            }
            if incoming.last.date > lane.last.date { lane.last = incoming.last }
            lane.days = Array(lane.days.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }.suffix(31))
            self.history[key] = lane
        }
    }

    public func project(
        account: String,
        window: QuotaWindow,
        now: Date,
        calendar: Calendar = .current) -> QuotaProjection
    {
        guard window.resetsAt > now else { return QuotaProjection(exhaustion: nil, method: "Awaiting reset refresh") }
        if window.remainingPercent == 0 { return QuotaProjection(exhaustion: now, method: "Already capped") }
        let today = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: -30, to: today) ?? today
        let days = (self.history[self.key(account: account, window: window)]?.days ?? [])
            .filter { $0.date >= cutoff && $0.date < today && $0.consumed.isFinite && $0.consumed > 0 }
        guard days.count >= 2 else {
            return QuotaProjection(exhaustion: nil, method: "Learning history")
        }
        let perDay = days.reduce(0) { $0 + $1.consumed } / Double(days.count)
        let date = now.addingTimeInterval(window.remainingPercent / perDay * 86400)
        let method = "30-day history · \(days.count) active days · "
            + String(format: "%.1f", perDay) + " percentage points/day. "
            + "Excludes today and days with no observed use; assumes future days are active. "
            + "Only observed changes are counted; usage while unobserved may be missed"
        return QuotaProjection(exhaustion: date < window.resetsAt ? date : nil, method: method)
    }
}
