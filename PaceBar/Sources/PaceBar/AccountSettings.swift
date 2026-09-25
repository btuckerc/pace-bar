import AppKit
import PaceBarCore
import SwiftUI

struct AccountSettings: View {
    let store: UsageStore
    @State private var hints: [AccountCandidate] = []
    @State private var error: String?
    @State private var adding: AccountProvider?
    @State private var signingOut: AccountEnrollment?

    var body: some View {
        Form {
            ForEach(AccountProvider.allCases, id: \.self) { provider in
                Section {
                    ForEach(self.store.configuration.accounts
                        .filter { $0.provider == provider && !$0.removed })
                    { entry in
                        AccountRow(entry: entry, identityHint: self.identityHint(for: entry)) { update in
                            self.change { config in
                                if let index = config.accounts.firstIndex(where: { $0.id == entry.id }) {
                                    update(&config.accounts[index])
                                }
                            }
                        } signOut: { self.signingOut = entry }
                    }
                    Button("Add \(provider.title) account…") { self.adding = provider }
                } header: {
                    Text(provider.title)
                } footer: {
                    Text(provider == .codex
                        ? "Removing stops tracking only; the sign-in and history stay, and you can add it back."
                        : "Removing stops tracking only; OMP keeps the sign-in, and you can add it back.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            OpenRouterKeySection(store: self.store)
            if let error = self.error { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .onAppear { self.rescan() }
        .sheet(item: self.$adding, onDismiss: self.rescan) { provider in
            AddAccountSheet(provider: provider, store: self.store)
        }
        .sheet(item: self.$signingOut, onDismiss: self.rescan) { entry in
            SignOutSheet(entry: entry, identityHint: self.identityHint(for: entry), store: self.store)
        }
    }

    private func identityHint(for entry: AccountEnrollment) -> String {
        Self.identityHint(for: entry, in: self.hints)
    }

    static func identityHint(for entry: AccountEnrollment, in candidates: [AccountCandidate]) -> String {
        candidates.first {
            $0.provider == entry.provider && $0.providerAccountID != nil
                && $0.providerAccountID == entry.providerAccountID
        }?.identityHint ?? entry.identityHint
    }

    /// Sign-ins on this Mac, tracked or not. Read-only; nothing is enrolled here.
    static func discover(_ configuration: Configuration) throws -> [AccountCandidate] {
        var found = try AccountDiscovery.codex(paths: AccountDiscovery.codexPaths(configuration))
        var databases = Set([ClaudeAccount.ompDatabase.path])
        for entry in configuration.accounts {
            if case let .omp(database, _) = entry.source {
                databases.insert(Configuration.expand(database).path)
            }
        }
        for database in databases.sorted() {
            found += try ClaudeAccount.candidates(database: URL(fileURLWithPath: database))
        }
        return found
    }

    private func rescan() {
        do {
            self.hints = try Self.discover(self.store.configuration)
            self.error = nil
        } catch { self.error = "Some sign-ins could not be read. Tracked accounts are unchanged." }
    }

    private func change(_ update: (inout Configuration) throws -> Void) {
        do {
            var config = self.store.configuration
            try update(&config)
            try self.store.apply(config)
            self.error = nil
        } catch { self.error = error.localizedDescription }
    }
}

extension AccountProvider: Identifiable {
    public var id: String {
        self.rawValue
    }
}

private struct AccountRow: View {
    let entry: AccountEnrollment
    let identityHint: String
    let update: ((inout AccountEnrollment) -> Void) -> Void
    let signOut: () -> Void
    @State private var label = ""
    @State private var renaming = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(self.entry.label)
                Text(self.entry.enabled ? self.identityHint : "Paused · \(self.identityHint)")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(self.sourceDescription)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Button("Rename…") {
                    self.label = self.entry.label
                    self.renaming = true
                }
                Button(self.entry.enabled ? "Pause Tracking" : "Resume Tracking") {
                    self.update { $0.enabled.toggle() }
                }
                Divider()
                Button("Remove") { self.update { $0.removed = true } }
                if case let .codexFiles(_, home) = self.entry.source, home != nil {
                    Button("Remove and Sign Out…") { self.signOut() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Actions for \(self.entry.label)")
        }
        .opacity(self.entry.enabled ? 1 : 0.6)
        .alert("Rename \(self.entry.label)", isPresented: self.$renaming) {
            TextField("Name", text: self.$label)
            Button("Rename") { self.rename() }.keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        }
    }

    private var sourceDescription: String {
        switch self.entry.source {
        case let .codexFiles(paths, _):
            paths.map { (Configuration.expand($0).path as NSString).abbreviatingWithTildeInPath }
                .joined(separator: "\n")
        case let .omp(database, _):
            (Configuration.expand(database).path as NSString).abbreviatingWithTildeInPath
        }
    }

    private func rename() {
        let trimmed = self.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != self.entry.label else { return }
        self.update { $0.label = trimmed }
    }
}

/// OpenRouter has one API key rather than subscriptions, so it is a single key file, read only.
private struct OpenRouterKeySection: View {
    let store: UsageStore
    @State private var error: String?

    var body: some View {
        let path = self.store.configuration.openRouterAuthFile
        let found = FileManager.default.isReadableFile(atPath: Configuration.expand(path).path)
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text((Configuration.expand(path).path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1).truncationMode(.middle)
                    Text(found ? "API key file" : "No readable file here.")
                        .font(.caption).foregroundStyle(found ? Color.secondary : Color.orange)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose…") { self.choose() }
            }
            if let error = self.error { Text(error).font(.caption).foregroundStyle(.red) }
        } header: {
            Text("OpenRouter")
        } footer: {
            Text("OpenCode's auth.json, or any private file with an \"apiKey\" field.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try Credentials.openRouter(Configuration.boundedRead(url.path))
            var config = self.store.configuration
            config.openRouterAuthFile = (url.path as NSString).abbreviatingWithTildeInPath
            try self.store.apply(config)
            self.error = nil
        } catch { self.error = "That file doesn't contain an OpenRouter API key." }
    }
}
