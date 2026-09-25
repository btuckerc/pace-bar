import Foundation

/// The small, quantized quota projection used by the menu-bar icon.
///
/// A slot is tied to an account label, so removing or adding another account does not make
/// existing bars move around. `nil` means that the account's reading is unavailable.
public struct QuotaIconState: Equatable, Sendable {
    public static let labels = CodexAccount.labels
    /// The Claude sign-in shown by the icon's separate Claude slot.
    public static let claudeLabel = "Claude 1"

    /// Codex 1–4 in twelve steps of remaining quota.
    public let levels: [Int?]
    /// Claude 1 in twelve steps of remaining quota.
    public let claude: Int?

    public static let unavailable = QuotaIconState(levels: [nil, nil, nil, nil], claude: nil)

    /// - Parameters:
    ///   - unavailable: Nothing is current (paused, asleep, or settings unreadable).
    ///   - claudeFreshness: Claude readings are paced to respect Anthropic's rate limit, so an hour is normal.
    public init(
        readings: [CodexReading],
        claude: [ClaudeReading] = [],
        now: Date,
        freshness: TimeInterval = 600,
        claudeFreshness: TimeInterval = 3600,
        unavailable: Bool = false,
        codexUnavailable: Bool = false,
        claudeUnavailable: Bool = false)
    {
        guard !unavailable else {
            self = Self.unavailable
            return
        }
        self.levels = codexUnavailable ? [nil, nil, nil, nil]
            : Self.codexLevels(readings, now: now, freshness: freshness)
        self.claude = claudeUnavailable ? nil
            : Self.claudeLevel(claude, now: now, freshness: claudeFreshness)
    }

    private init(levels: [Int?], claude: Int?) {
        self.levels = levels
        self.claude = claude
    }

    private static func codexLevels(_ readings: [CodexReading], now: Date, freshness: TimeInterval) -> [Int?] {
        var projected = [Int?](repeating: nil, count: Self.labels.count)
        guard freshness >= 0,
              readings.count <= Self.labels.count,
              Set(readings.map(\.id)).count == readings.count,
              Set(readings.map(\.label)).count == readings.count,
              readings.allSatisfy({ Self.labels.contains($0.label) })
        else { return projected }

        for reading in readings {
            guard let slot = Self.labels.firstIndex(of: reading.label),
                  reading.error == nil,
                  let updated = reading.updated,
                  Self.isFresh(updated, now: now, freshness: freshness),
                  let snapshot = reading.snapshot
            else { continue }

            // Additional/model-specific lanes are intentionally excluded. The icon represents
            // the account's ordinary subscription windows only.
            let mainWindows = snapshot.windows.filter { $0.lane == nil }
            guard !mainWindows.isEmpty else { continue }
            projected[slot] = Self.level(mainWindows, now: now)
        }
        return projected
    }

    private static func claudeLevel(_ readings: [ClaudeReading], now: Date, freshness: TimeInterval) -> Int? {
        let matches = readings.filter { $0.label == Self.claudeLabel }
        guard matches.count == 1, let reading = matches.first,
              reading.error == nil,
              let updated = reading.updated,
              Self.isFresh(updated, now: now, freshness: freshness),
              let windows = reading.windows
        else { return nil }
        // Windows whose reset has passed are already refilled or dropped by the tracker; none left means unused.
        return windows.isEmpty ? 12 : Self.level(windows, now: now)
    }

    private static func isFresh(_ updated: Date, now: Date, freshness: TimeInterval) -> Bool {
        freshness >= 0 && now.timeIntervalSince(updated) >= 0 && now.timeIntervalSince(updated) <= freshness
    }

    /// The binding (least remaining) window, rounded up so any remaining quota stays visible.
    private static func level(_ windows: [QuotaWindow], now: Date) -> Int? {
        guard windows.allSatisfy({
            $0.usedPercent.isFinite && (0...100).contains($0.usedPercent) && $0.resetsAt > now
        }) else { return nil }
        let remaining = windows.map { 100 - $0.usedPercent }.min() ?? 0
        return min(12, max(0, Int(ceil(remaining * 12 / 100))))
    }
}
