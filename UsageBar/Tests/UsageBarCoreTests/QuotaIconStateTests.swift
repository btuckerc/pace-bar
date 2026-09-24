import Foundation
import Testing
@testable import UsageBarCore

struct QuotaIconStateTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func reading(
        _ label: String,
        id: String? = nil,
        used: [Double] = [25],
        updated: Date? = nil,
        error: String? = nil,
        resetOffset: TimeInterval = 3600,
        additional: Bool = false) -> CodexReading
    {
        let windows = used.enumerated().map { index, value in
            QuotaWindow(
                id: "window-\(index)", label: "window", periodSeconds: 300,
                lane: additional ? "model" : nil, usedPercent: value,
                resetsAt: self.now.addingTimeInterval(resetOffset))
        }
        return CodexReading(
            id: id ?? label, label: label,
            snapshot: CodexSnapshot(windows: windows, plan: "pro", availableResets: nil),
            updated: updated ?? self.now, error: error)
    }

    @Test func `Slots stay attached to fixed account aliases`() {
        let state = QuotaIconState(readings: [
            self.reading("Codex 4", used: [50]), self.reading("Codex 1", used: [0]),
        ], now: self.now)
        #expect(state.levels == [12, nil, nil, 6])
    }

    @Test func `Missing and ambiguous accounts remain unknown`() {
        let duplicateID = [self.reading("Codex 1", id: "same"), self.reading("Codex 2", id: "same")]
        #expect(QuotaIconState(readings: duplicateID, now: self.now) == .unavailable)

        let duplicateLabel = [self.reading("Codex 1", id: "a"), self.reading("Codex 1", id: "b")]
        #expect(QuotaIconState(readings: duplicateLabel, now: self.now) == .unavailable)

        let unknownLabel = [self.reading("other")]
        #expect(QuotaIconState(readings: unknownLabel, now: self.now) == .unavailable)

        let missing = QuotaIconState(readings: [self.reading("Codex 1")], now: self.now)
        #expect(missing.levels == [9, nil, nil, nil])
    }

    @Test func `Stale failed and reset readings never become a balance`() {
        #expect(QuotaIconState(
            readings: [self.reading("Codex 1", updated: self.now.addingTimeInterval(-601))], now: self.now)
            .levels == [nil, nil, nil, nil])
        #expect(QuotaIconState(
            readings: [self.reading("Codex 1", updated: self.now.addingTimeInterval(1))], now: self.now)
            .levels == [nil, nil, nil, nil])
        #expect(QuotaIconState(
            readings: [self.reading("Codex 1", error: "offline")], now: self.now)
            .levels == [nil, nil, nil, nil])
        #expect(QuotaIconState(
            readings: [self.reading("Codex 1", resetOffset: 0)], now: self.now)
            .levels == [nil, nil, nil, nil])
        #expect(QuotaIconState(
            readings: [self.reading("Codex 1", additional: true)], now: self.now)
            .levels == [nil, nil, nil, nil])
    }

    @Test func `The binding ordinary quota excludes model-specific allowances`() {
        let state = QuotaIconState(readings: [
            self.reading("Codex 1", used: [25, 75])
                .addingAdditionalWindow(used: 100, now: self.now),
        ], now: self.now)
        #expect(state.levels == [3, nil, nil, nil])
    }

    @Test func `Invalid percentages stay unknown and positive quotas differ from zero`() {
        for used: Double in [-1, 101, .infinity, -.infinity, .nan] {
            #expect(QuotaIconState(readings: [self.reading("Codex 1", used: [used])], now: self.now)
                .levels == [nil, nil, nil, nil])
        }
        #expect(QuotaIconState(readings: [self.reading("Codex 1", used: [100])], now: self.now).levels[0] == 0)
        #expect(QuotaIconState(readings: [self.reading("Codex 1", used: [99.99])], now: self.now).levels[0] == 1)
        #expect(QuotaIconState(readings: [self.reading("Codex 1", used: [0])], now: self.now).levels[0] == 12)
    }

    private func claude(
        _ used: [Double]? = [24, 4],
        label: String = "Claude 1",
        updated: TimeInterval = -1800,
        error: String? = nil) -> ClaudeReading
    {
        ClaudeReading(
            id: label, label: label,
            windows: used?.enumerated().map { index, value in
                QuotaWindow(
                    id: "claude-\(index)", label: "window", periodSeconds: index == 0 ? 604_800 : 18000,
                    lane: nil, usedPercent: value, resetsAt: self.now.addingTimeInterval(3600))
            },
            updated: self.now.addingTimeInterval(updated), error: error)
    }

    @Test func `Claude shows its binding window and an unused allowance as full`() {
        #expect(QuotaIconState(readings: [], claude: [self.claude([24, 90])], now: self.now).claude == 2)
        #expect(QuotaIconState(readings: [], claude: [self.claude([])], now: self.now).claude == 12)
        #expect(QuotaIconState(readings: [], claude: [self.claude(label: "Claude 2")], now: self.now).claude == nil)
    }

    @Test func `Claude paced readings stay current for an hour, then become unavailable`() {
        #expect(QuotaIconState(readings: [], claude: [self.claude(updated: -3600)], now: self.now).claude == 10)
        #expect(QuotaIconState(readings: [], claude: [self.claude(updated: -3601)], now: self.now).claude == nil)
        #expect(QuotaIconState(readings: [], claude: [self.claude(error: "offline")], now: self.now).claude == nil)
        #expect(QuotaIconState(readings: [], claude: [self.claude(nil)], now: self.now).claude == nil)
    }

    @Test func `A failure of one provider leaves the other provider readable`() {
        let codex = [self.reading("Codex 1", used: [0])]
        let claude = [self.claude()]
        let codexDown = QuotaIconState(readings: codex, claude: claude, now: self.now, codexUnavailable: true)
        #expect(codexDown.levels == [nil, nil, nil, nil])
        #expect(codexDown.claude == 10)
        let claudeDown = QuotaIconState(readings: codex, claude: claude, now: self.now, claudeUnavailable: true)
        #expect(claudeDown.levels == [12, nil, nil, nil])
        #expect(claudeDown.claude == nil)
        #expect(QuotaIconState(readings: codex, claude: claude, now: self.now, unavailable: true) == .unavailable)
    }
}

extension CodexReading {
    fileprivate func addingAdditionalWindow(used: Double, now: Date) -> CodexReading {
        var windows = self.snapshot?.windows ?? []
        windows.append(QuotaWindow(
            id: "additional", label: "additional", periodSeconds: 300, lane: "model",
            usedPercent: used, resetsAt: now.addingTimeInterval(3600)))
        return CodexReading(
            id: self.id, label: self.label,
            snapshot: CodexSnapshot(windows: windows, plan: self.snapshot?.plan, availableResets: nil),
            updated: self.updated, error: self.error)
    }
}
