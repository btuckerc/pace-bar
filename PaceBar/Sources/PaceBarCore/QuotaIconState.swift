import Foundation

public struct IconAccount: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let level: Int?
}

/// Provider-separated projection. Order is enrollment order, never label matching.
public struct QuotaIconState: Equatable, Sendable {
    public let codex: [IconAccount]
    public let claude: [IconAccount]

    public struct Group: Equatable, Sendable {
        public let provider: AccountProvider
        public let accounts: [IconAccount]
        public var summarized: Bool {
            self.accounts.count > 6
        }

        public var levels: [Int?] {
            guard self.summarized else { return self.accounts.map(\.level) }
            return [self.accounts.allSatisfy { $0.level != nil } ? self.accounts.compactMap(\.level).min() : nil]
        }
    }

    public var groups: [Group] {
        [Group(provider: .codex, accounts: self.codex), Group(provider: .claude, accounts: self.claude)]
            .filter { !$0.accounts.isEmpty }
    }

    public var accessibilityDescription: String {
        let lines = self.groups.flatMap { group in
            group.accounts.map { account in
                "\(group.provider.title), \(account.label): " +
                    (account.level.map { "\($0 * 100 / 12)% remaining" } ?? "unavailable")
            }
        }
        return lines.isEmpty ? "Pace Bar — no active accounts" : "Pace Bar — quota remaining\n" + lines
            .joined(separator: "\n")
    }

    public static let unavailable = QuotaIconState(readings: [], now: .distantPast)

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
        let codexIDs = Dictionary(grouping: readings, by: \.id)
        self.codex = readings.map { reading in
            let valid = !unavailable && !codexUnavailable && codexIDs[reading.id]?.count == 1
                && reading.error == nil && Self.isFresh(reading.updated, now: now, freshness: freshness)
            let windows = reading.snapshot?.windows.filter { $0.lane == nil } ?? []
            return IconAccount(
                id: reading.id,
                label: reading.label,
                level: valid && !windows.isEmpty ? Self.level(windows, now: now) : nil)
        }
        let claudeIDs = Dictionary(grouping: claude, by: \.id)
        self.claude = claude.map { reading in
            let valid = !unavailable && !claudeUnavailable && claudeIDs[reading.id]?.count == 1
                && reading.error == nil && Self.isFresh(reading.updated, now: now, freshness: claudeFreshness)
            return IconAccount(
                id: reading.id,
                label: reading.label,
                level: valid ? reading.windows
                    .flatMap { $0.isEmpty ? 12 : Self.level($0, now: now) } : nil)
        }
    }

    private static func isFresh(_ updated: Date?, now: Date, freshness: TimeInterval) -> Bool {
        guard let updated else { return false }
        return freshness >= 0 && now.timeIntervalSince(updated) >= 0 && now.timeIntervalSince(updated) <= freshness
    }

    private static func level(_ windows: [QuotaWindow], now: Date) -> Int? {
        guard windows.allSatisfy({
            $0.usedPercent.isFinite && (0...100).contains($0.usedPercent) && $0.resetsAt > now
        }) else { return nil }
        let remaining = windows.map { 100 - $0.usedPercent }.min() ?? 0
        return min(12, max(0, Int(ceil(remaining * 12 / 100))))
    }
}
