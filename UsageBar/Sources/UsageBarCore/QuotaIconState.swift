import Foundation

/// The small, quantized quota projection used by the menu-bar icon.
///
/// A slot is tied to an account label, so removing or adding another account does not make
/// existing bars move around. `nil` means that the account's reading is unavailable.
public struct QuotaIconState: Equatable, Sendable {
    public static let labels = CodexAccount.labels

    public let levels: [Int?]

    public static let unavailable = QuotaIconState(levels: [nil, nil, nil, nil])

    public init(
        readings: [CodexReading],
        now: Date,
        freshness: TimeInterval = 600,
        unavailable: Bool = false)
    {
        guard !unavailable, freshness >= 0,
              readings.count <= Self.labels.count,
              Set(readings.map(\.id)).count == readings.count,
              Set(readings.map(\.label)).count == readings.count,
              readings.allSatisfy({ Self.labels.contains($0.label) })
        else {
            self = Self.unavailable
            return
        }

        var projected = [Int?](repeating: nil, count: Self.labels.count)
        for reading in readings {
            guard let slot = Self.labels.firstIndex(of: reading.label),
                  reading.error == nil,
                  let updated = reading.updated,
                  now.timeIntervalSince(updated) >= 0,
                  now.timeIntervalSince(updated) <= freshness,
                  let snapshot = reading.snapshot
            else { continue }

            // Additional/model-specific lanes are intentionally excluded. The icon represents
            // the account's ordinary subscription windows only.
            let mainWindows = snapshot.windows.filter { $0.lane == nil }
            guard !mainWindows.isEmpty,
                  mainWindows.allSatisfy({
                      $0.usedPercent.isFinite && (0...100).contains($0.usedPercent)
                          && $0.resetsAt > now
                  })
            else { continue }

            let remaining = mainWindows.map { 100 - $0.usedPercent }.min() ?? 0
            projected[slot] = min(12, max(0, Int(ceil(remaining * 12 / 100))))
        }
        self.levels = projected
    }

    private init(levels: [Int?]) {
        self.levels = levels
    }
}
