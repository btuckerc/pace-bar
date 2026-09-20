import ServiceManagement
import SwiftUI
import UsageBarCore

struct SettingsView: View {
    let store: UsageStore
    @State private var draft = Configuration()
    @State private var error: String?
    @State private var electricityRate = ""
    @State private var metricsURL = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Accounts") {
                TextField("Codex auth file", text: self.$draft.codexAuthFile)
                TextField("OpenRouter auth file", text: self.$draft.openRouterAuthFile)
                Text(
                    "Also discovers ~/.codex-t3/* and ~/.codex-gui/*. Deduplicates account IDs. Sign-ins stay read-only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("nous") {
                TextField("Server URL", text: self.$draft.nousURL)
                TextField("Metrics URL (optional)", text: self.$metricsURL)
                TextField("SSH fallback host", text: self.$draft.nousSSHHost)
                Toggle("Read host utilization", isOn: self.$draft.hostUtilization)
                TextField("Electricity $/kWh (optional)", text: self.$electricityRate)
            }
            Section {
                Toggle("Launch at login", isOn: self.$launchAtLogin)
                    .onChange(of: self.launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch { self.error = error.localizedDescription }
                    }
                Text("Cloud: every 5 minutes. nous: every minute. Slower in Low Power Mode. Pause stops all polling.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = self.error { Text(error).font(.caption).foregroundStyle(.red) }
                HStack {
                    Link("Source & updates", destination: URL(string: "https://github.com/btuckerc/usage-bar")!)
                    Spacer()
                    Button("Save") {
                        do {
                            let rate = self.electricityRate.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !rate.isEmpty, Double(rate) == nil {
                                throw UsageError.message("Enter a numeric USD/kWh rate.")
                            }
                            self.draft.electricityUSDPerKWh = Double(rate)
                            self.draft.nousMetricsURL = self.metricsURL.isEmpty ? nil : self.metricsURL
                            try self.store.apply(self.draft)
                            self.error = nil
                        } catch { self.error = error.localizedDescription }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 490)
        .onAppear {
            self.draft = self.store.configuration
            self.metricsURL = self.draft.nousMetricsURL ?? ""
            self.electricityRate = self.draft.electricityUSDPerKWh.map { String($0) } ?? ""
        }
    }
}
