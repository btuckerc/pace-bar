import Foundation

/// Runs small history reads/writes away from the UI actor, only alongside existing cloud refreshes.
public actor QuotaHistoryStore {
    private let file: URL
    private var forecast: QuotaForecast?

    public init(file: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/usage-bar/quota-history.json"))
    {
        self.file = file
    }

    private func load() {
        if self.forecast == nil {
            // Cap input size and fail closed to fresh history if an old file is unreadable or malformed.
            let size = (try? self.file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size <= 1_048_576, let data = try? Data(contentsOf: self.file) {
                self.forecast = try? JSONDecoder().decode(QuotaForecast.self, from: data)
            }
            if self.forecast == nil { self.forecast = QuotaForecast() }
        }
    }

    public func record(_ readings: [CodexReading]) -> (QuotaForecast, Bool) {
        self.load()
        var current = self.forecast ?? QuotaForecast()
        for reading in readings {
            if reading.error == nil, let snapshot = reading.snapshot, let date = reading.updated {
                current.record(account: reading.id, windows: snapshot.windows, at: date)
            }
        }
        return self.save(current)
    }

    private func save(_ current: QuotaForecast) -> (QuotaForecast, Bool) {
        self.forecast = current
        do {
            try FileManager.default.createDirectory(
                at: self.file.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(current).write(to: self.file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.file.path)
            return (current, true)
        } catch {
            return (current, false)
        }
    }

    public func importHistory(_ data: Data, readings: [CodexReading], now: Date) throws -> QuotaForecast {
        self.load()
        let merged = try QuotaBackfill.merge(data, into: self.forecast ?? QuotaForecast(), readings: readings, now: now)
        let (saved, success) = self.save(merged)
        guard success else { throw UsageError.message("Could not save imported quota history.") }
        return saved
    }
}
