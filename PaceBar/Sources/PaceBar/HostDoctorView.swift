import PaceBarCore
import SwiftUI

/// Checks a host, shows exactly what setup would run, and runs it only when the user clicks Run Setup.
struct HostDoctorView: View {
    let host: InferenceHost
    @Environment(\.dismiss) private var dismiss
    @State private var doctor = HostDoctor()
    @State private var phase = Phase.checking
    @State private var checks: [DoctorCheck] = []
    @State private var plan: SetupPlan?
    @State private var steps: [Step] = []
    @State private var message: String?
    @State private var task: Task<Void, Never>?

    private enum Phase { case checking, ready, running, done, failed }

    private struct Step: Identifiable {
        let id: Int
        let title: String
        var state: DoctorState?
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Checks") {
                    if self.phase == .checking {
                        HStack { ProgressView().controlSize(.small); Text("Checking \(self.host.name)…") }
                    }
                    ForEach(self.checks) { check in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(check.requirement)
                                Text(check.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Self.icon(check.state)
                        }
                    }
                }
                if let plan = self.plan, !plan.steps.isEmpty, self.phase != .checking {
                    Section {
                        ForEach(self.stepRows(plan)) { step in
                            Label {
                                Text(step.title)
                            } icon: {
                                if self.phase == .running, step.state == nil,
                                   step.id == self.steps.first(where: { $0.state == nil })?.id
                                {
                                    ProgressView().controlSize(.small)
                                } else if let state = step.state {
                                    Self.icon(state)
                                } else {
                                    Image(systemName: "circle").foregroundStyle(.secondary)
                                }
                            }
                        }
                        DisclosureGroup("Commands") {
                            ForEach(Array(plan.steps.enumerated()), id: \.offset) { _, step in
                                Text(step.displayScript)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    } header: {
                        Text("Setup will run")
                    } footer: {
                        Text(plan.disclosure).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let summary = self.summary {
                    Section { Text(summary.text).foregroundStyle(summary.color) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if self.phase == .failed || self.phase == .done {
                    Button("Check Again") { self.check() }
                }
                Spacer()
                if self.phase == .running {
                    Button("Stop") { self.task?.cancel() }
                } else {
                    Button("Close") { self.dismiss() }.keyboardShortcut(.cancelAction)
                }
                if self.phase == .ready, let plan = self.plan {
                    Button("Run Setup") { self.run(plan) }.keyboardShortcut(.defaultAction)
                }
            }
            .padding()
        }
        .frame(width: 560, height: 560)
        .interactiveDismissDisabled(self.phase == .running)
        .task { self.check() }
        .onDisappear { self.task?.cancel() }
    }

    private var summary: (text: String, color: Color)? {
        if let message = self.message { return (message, .red) }
        switch self.phase {
        case .checking, .running: return nil
        case .ready: return ("Review the steps, then click Run Setup. Nothing changes until you do.", .secondary)
        case .done, .failed:
            if self.checks.allSatisfy({ $0.state == .passed }) { return ("Everything is set up.", .green) }
            return ("Some checks need attention that Pace Bar can't fix automatically.", .orange)
        }
    }

    private func stepRows(_ plan: SetupPlan) -> [Step] {
        self.steps.isEmpty
            ? plan.steps.enumerated().map { Step(id: $0.offset, title: $0.element.title) }
            : self.steps
    }

    @ViewBuilder
    private static func icon(_ state: DoctorState) -> some View {
        switch state {
        case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .unsupported: Image(systemName: "questionmark.circle.fill").foregroundStyle(.secondary)
        }
    }

    private func check() {
        self.task?.cancel()
        self.phase = .checking
        self.checks = []
        self.steps = []
        self.plan = nil
        self.message = nil
        self.task = Task {
            let checks = await self.doctor.inspect(self.host)
            guard !Task.isCancelled else { return }
            self.checks = checks
            do {
                let plan = try await self.doctor.plan(self.host, checks: checks)
                self.plan = plan
                self.phase = plan.steps.isEmpty ? .done : .ready
            } catch {
                self.message = error.localizedDescription
                self.phase = .failed
            }
        }
    }

    private func run(_ plan: SetupPlan) {
        self.phase = .running
        self.message = nil
        self.steps = plan.steps.enumerated().map { Step(id: $0.offset, title: $0.element.title) }
        self.task = Task {
            do {
                for try await event in self.doctor.run(plan) {
                    switch event {
                    case .started:
                        break
                    case let .completed(index, _):
                        if self.steps.indices.contains(index) { self.steps[index].state = .passed }
                    case let .rollback(output):
                        self.message = "Setup failed and was rolled back. \(output)"
                    case let .verified(checks):
                        self.checks = checks
                    }
                }
                self.phase = .done
            } catch {
                if let index = self.steps.firstIndex(where: { $0.state == nil }) { self.steps[index].state = .failed }
                self.message = error.localizedDescription
                self.phase = .failed
            }
        }
    }
}
