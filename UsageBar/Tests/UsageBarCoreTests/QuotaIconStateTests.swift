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
            self.reading("btc", used: [50]), self.reading("primary", used: [0]),
        ], now: self.now)
        #expect(state.levels == [12, nil, nil, 6])
    }

    @Test func `Missing and ambiguous accounts remain unknown`() {
        let duplicateID = [self.reading("primary", id: "same"), self.reading("secondary", id: "same")]
        #expect(QuotaIconState(readings: duplicateID, now: self.now) == .unavailable)

        let duplicateLabel = [self.reading("primary", id: "a"), self.reading("primary", id: "b")]
        #expect(QuotaIconState(readings: duplicateLabel, now: self.now) == .unavailable)

        let unknownLabel = [self.reading("other")]
        #expect(QuotaIconState(readings: unknownLabel, now: self.now) == .unavailable)

        let missing = QuotaIconState(readings: [self.reading("primary")], now: self.now)
        #expect(missing.levels == [9, nil, nil, nil])
    }

    @Test func `Stale failed and reset readings never become a balance`() {
        #expect(QuotaIconState(
            readings: [self.reading("primary", updated: self.now.addingTimeInterval(-601))], now: self.now)
            .levels == [nil, nil, nil, nil])
        #expect(QuotaIconState(
            readings: [self.reading("primary", updated: self.now.addingTimeInterval(1))], now: self.now)
            .levels == [nil, nil, nil, nil])
        #expect(QuotaIconState(
            readings: [self.reading("primary", error: "offline")], now: self.now)
            .levels == [nil, nil, nil, nil])
        #expect(QuotaIconState(
            readings: [self.reading("primary", resetOffset: 0)], now: self.now)
            .levels == [nil, nil, nil, nil])
        #expect(QuotaIconState(
            readings: [self.reading("primary", additional: true)], now: self.now)
            .levels == [nil, nil, nil, nil])
    }

    @Test func `The binding ordinary quota excludes model-specific allowances`() {
        let state = QuotaIconState(readings: [
            self.reading("primary", used: [25, 75])
                .addingAdditionalWindow(used: 100, now: self.now),
        ], now: self.now)
        #expect(state.levels == [3, nil, nil, nil])
    }

    @Test func `Invalid percentages stay unknown and positive quotas differ from zero`() {
        for used: Double in [-1, 101, .infinity, -.infinity, .nan] {
            #expect(QuotaIconState(readings: [self.reading("primary", used: [used])], now: self.now)
                .levels == [nil, nil, nil, nil])
        }
        #expect(QuotaIconState(readings: [self.reading("primary", used: [100])], now: self.now).levels[0] == 0)
        #expect(QuotaIconState(readings: [self.reading("primary", used: [99.99])], now: self.now).levels[0] == 1)
        #expect(QuotaIconState(readings: [self.reading("primary", used: [0])], now: self.now).levels[0] == 12)
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
