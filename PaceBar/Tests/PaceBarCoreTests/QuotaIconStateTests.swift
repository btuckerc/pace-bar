import Foundation
import Testing
@testable import PaceBarCore

struct QuotaIconStateTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func reading(_ id: String, used: Double = 25, age: Double = 0, error: String? = nil) -> CodexReading {
        CodexReading(id: id, label: "Custom \(id)", snapshot: CodexSnapshot(windows: [
            QuotaWindow(
                id: "week",
                label: "Week",
                periodSeconds: 604_800,
                lane: nil,
                usedPercent: used,
                resetsAt: self.now.addingTimeInterval(3600)),
        ], plan: "pro", availableResets: nil), updated: self.now.addingTimeInterval(-age), error: error)
    }

    private func claude(_ id: String, age: Double = 0) -> ClaudeReading {
        ClaudeReading(
            id: id,
            label: "Claude \(id)",
            windows: [],
            updated: self.now.addingTimeInterval(-age),
            error: nil)
    }

    @Test func `Both provider projections retain zero one two and many active accounts`() {
        for count in [0, 1, 2, 8] {
            let state = QuotaIconState(
                readings: (0..<count).map { self.reading(String($0)) },
                claude: (0..<count).map { self.claude(String($0)) },
                now: self.now)
            #expect(state.codex.map(\.id) == (0..<count).map(String.init))
            #expect(state.claude.map(\.id) == (0..<count).map(String.init))
            #expect(state.groups.map(\.provider) == (count == 0 ? [] : [.codex, .claude]))
            if count > 6 {
                #expect(state.groups.map(\.levels) == [[9], [12]])
                #expect(state.accessibilityDescription.contains("Claude 7"))
            }
        }
    }

    @Test func `Labels do not determine icon positions or availability`() {
        let state = QuotaIconState(
            readings: [self.reading("four", used: 50), self.reading("one", used: 0)],
            now: self.now)
        #expect(state.codex.map(\.level) == [6, 12])
        let duplicates = QuotaIconState(readings: [self.reading("same"), self.reading("same")], now: self.now)
        #expect(duplicates.codex.map(\.level) == [nil, nil])
    }

    @Test func `Stale failed future and invalid readings remain unavailable`() {
        for reading in [
            self.reading("a", age: 601),
            self.reading("a", age: -1),
            self.reading("a", error: "offline"),
            self.reading("a", used: -1),
            self.reading("a", used: 101),
            self.reading("a", used: .nan),
        ] {
            #expect(QuotaIconState(readings: [reading], now: self.now).codex.first?.level == nil)
        }
        #expect(QuotaIconState(readings: [self.reading("a", used: 100)], now: self.now).codex.first?.level == 0)
        #expect(QuotaIconState(readings: [self.reading("a", used: 99.99)], now: self.now).codex.first?.level == 1)
    }

    @Test func `Provider failures and overflow never hide the other provider`() {
        let state = QuotaIconState(
            readings: (0..<7).map { self.reading(String($0), error: $0 == 6 ? "offline" : nil) },
            claude: [self.claude("one")],
            now: self.now)
        #expect(state.groups[0].levels == [nil])
        #expect(state.groups[1].levels == [12])
        let down = QuotaIconState(
            readings: [self.reading("a")],
            claude: [self.claude("one")],
            now: self.now,
            codexUnavailable: true)
        #expect(down.codex.first?.level == nil)
        #expect(down.claude.first?.level == 12)
        #expect(QuotaIconState(readings: [], claude: [self.claude("one", age: 3600)], now: self.now).claude.first?
            .level == 12)
        #expect(QuotaIconState(readings: [], claude: [self.claude("one", age: 3601)], now: self.now).claude.first?
            .level == nil)
    }
}
