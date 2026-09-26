import PaceBarCore
import SwiftUI

struct HostSettings: View {
    let store: UsageStore
    @State private var editing: InferenceHost?
    @State private var doctorHost: InferenceHost?
    @State private var pendingCheckHostID: UUID?
    @State private var removing: InferenceHost?
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                ForEach(self.store.configuration.hosts) { host in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            let status = self.status(for: host)
                            HStack(spacing: 6) {
                                Text(host.name)
                                Circle().fill(status.tint).frame(width: 7, height: 7)
                                    .accessibilityHidden(true)
                                Text(status.label).font(.caption).foregroundStyle(.secondary)
                            }
                            .help(status.detail ?? status.label)
                            .accessibilityElement(children: .combine)
                            PrivateText(text: self.address(of: host), name: "\(host.name) address and model")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Check Setup…") { self.doctorHost = host }
                        Menu {
                            Button("Edit…") { self.editing = host }
                            Divider()
                            Button("Remove…") { self.removing = host }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("Actions for \(host.name)")
                    }
                }
                Button("Add Host…") {
                    self.editing = InferenceHost(
                        name: "New host",
                        serverURL: "http://localhost:8080",
                        sshHost: nil,
                        hostUtilization: false)
                }
            }
            if let error = self.error { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .sheet(item: self.$editing, onDismiss: self.checkNewHost) { host in
            HostEditor(store: self.store, host: host) { saved in self.pendingCheckHostID = saved.id }
        }
        .sheet(item: self.$doctorHost) { host in HostDoctorView(host: host) }
        .confirmationDialog("Remove \(self.removing?.name ?? "host")?", item: self.$removing) { host in
            Button("Remove", role: .destructive) { self.change { $0.hosts.removeAll { $0.id == host.id } } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("History and remote services are kept.") }
    }

    /// A newly added host goes straight to Check Setup, so adding and setting up are one flow.
    private func checkNewHost() {
        guard let id = self.pendingCheckHostID else { return }
        self.pendingCheckHostID = nil
        self.doctorHost = self.store.configuration.hosts.first { $0.id == id }
    }

    /// Server URL, plus the loaded model once one is known.
    private func address(of host: InferenceHost) -> String {
        guard let model = self.store.hostReadings[host.id]?.nous?.model else { return host.serverURL }
        return "\(host.serverURL) · \(model)"
    }

    /// Short, identity-free state for the row; `detail` (errors, pause reasons) goes in the tooltip.
    private func status(for host: InferenceHost) -> (label: String, tint: Color, detail: String?) {
        guard host.enabled else { return ("Disabled", .secondary, nil) }
        if let pause = self.store.hostReadings[host.id]?.pause {
            return (pause.label, .secondary, pause.reason)
        }
        if let error = self.store.errors[UsageStore.hostKey(host.id, hardware: false)] {
            return (self.store.inferenceDownLabel(host.id), .orange, error)
        }
        if self.store.hostReadings[host.id]?.nous != nil { return ("Connected", Palette.local, nil) }
        return ("Waiting for data", .secondary, nil)
    }

    private func change(_ mutate: (inout Configuration) -> Void) {
        do {
            var config = self.store.configuration
            mutate(&config)
            try self.store.apply(config)
            self.error = nil
        } catch { self.error = error.localizedDescription }
    }
}

private struct HostEditor: View {
    let store: UsageStore
    let onSave: (InferenceHost) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var host: InferenceHost
    @State private var ssh: String
    @State private var metrics: String
    @State private var rate: String
    @State private var error: String?

    init(store: UsageStore, host: InferenceHost, onSave: @escaping (InferenceHost) -> Void) {
        self.store = store
        self.onSave = onSave
        self._host = State(initialValue: host)
        self._ssh = State(initialValue: host.sshHost ?? "")
        self._metrics = State(initialValue: host.metricsURL ?? "")
        self._rate = State(initialValue: host.electricityUSDPerKWh.map { String($0) } ?? "")
    }

    var body: some View {
        Form {
            TextField("Name", text: self.$host.name)
            TextField("Server URL", text: self.$host.serverURL)
            TextField("SSH host (optional)", text: self.$ssh)
            TextField("Metrics URL (optional)", text: self.$metrics)
            Toggle("Read hardware utilization", isOn: self.$host.hostUtilization)
            TextField("Electricity USD/kWh (optional)", text: self.$rate)
            Text("Changing the server URL starts a new history. With no metrics URL, Pace Bar samples hardware "
                + "read-only over your SSH alias and config, which may run local commands.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = self.error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { self.dismiss() }
                Spacer()
                Button("Save Host") {
                    do {
                        let rate = self.rate.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard rate.isEmpty || Double(rate) != nil
                        else { throw UsageError.message("Enter a numeric electricity rate.") }
                        self.host.sshHost = self.ssh.isEmpty ? nil : self.ssh
                        self.host.metricsURL = self.metrics.isEmpty ? nil : self.metrics
                        self.host.electricityUSDPerKWh = Double(rate)
                        var config = self.store.configuration
                        let added = !config.hosts.contains(where: { $0.id == self.host.id })
                        if let index = config.hosts.firstIndex(where: { $0.id == self.host.id }) {
                            config.hosts[index] = self.host
                        } else {
                            config.hosts.append(self.host)
                        }
                        try self.store.apply(config)
                        if added { self.onSave(self.host) }
                        self.dismiss()
                    } catch { self.error = error.localizedDescription }
                }
            }
        }.formStyle(.grouped).frame(width: 560, height: 430)
    }
}
