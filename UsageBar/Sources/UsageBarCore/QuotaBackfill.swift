import Foundation

/// Explicit, one-time import; never scans session logs during normal app operation.
public enum QuotaBackfill {
    private struct Sample: Decodable {
        let account: String
        let date: Double
        let used: Double
        let period: Double
        let reset: Double
        let plan: String?
    }

    public static func merge(
        _ data: Data,
        into existing: QuotaForecast,
        readings: [CodexReading],
        now: Date,
        calendar: Calendar = .current) throws -> QuotaForecast
    {
        guard data.count <= 64 * 1024 * 1024 else { throw UsageError.message("History import is too large.") }
        let samples = try JSONDecoder().decode([Sample].self, from: data)
        guard samples.count <= 500_000 else { throw UsageError.message("Too many history samples.") }
        let cutoff = calendar.date(byAdding: .day, value: -30, to: calendar.startOfDay(for: now)) ?? now
        var imported = QuotaForecast()
        for sample in samples.sorted(by: { $0.date < $1.date }) {
            let date = Date(timeIntervalSince1970: sample.date)
            guard date >= cutoff, date <= now,
                  let reading = readings.first(where: { $0.id == sample.account && $0.error == nil }),
                  let snapshot = reading.snapshot, let plan = sample.plan, plan == snapshot.plan else { continue }
            // Duration is authoritative: a weekly allowance may move from secondary to primary.
            let matches = snapshot.windows.filter { $0.lane == nil && $0.periodSeconds == sample.period }
            guard matches.count == 1, let current = matches.first else { continue }
            let historical = QuotaWindow(
                id: current.id, label: current.label, periodSeconds: current.periodSeconds, lane: nil,
                usedPercent: sample.used, resetsAt: Date(timeIntervalSince1970: sample.reset))
            imported.record(account: reading.id, windows: [historical], at: date, calendar: calendar)
        }
        var result = existing
        result.mergeHistory(imported, now: now, calendar: calendar)
        return result
    }
}
