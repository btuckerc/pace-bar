import AppKit
import PaceBarCore
import SwiftUI

/// One place to add an account: sign-ins already on this Mac (including removed ones) are one click;
/// a new sign-in runs the provider's own login with the exact command shown on the button's sheet.
struct AddAccountSheet: View {
    let provider: AccountProvider
    let store: UsageStore
    @Environment(\.dismiss) private var dismiss
    @State private var found: [AccountCandidate] = []
    @State private var session = AccountSignIn()
    @State private var plan: AccountLoginPlan?
    @State private var unavailable: String?
    @State private var error: String?
    @State private var answer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a \(self.provider.title) account").font(.headline)
            if !self.onThisMac.isEmpty {
                Text("On this Mac").font(.subheadline).foregroundStyle(.secondary)
                ForEach(self.onThisMac, id: \.candidate.id) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            PrivateText(text: item.candidate.identityHint, name: "email address")
                            if let previous = item.previous {
                                Text("Previously \(previous)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Add") { self.enroll(item.candidate) }
                    }
                }
                Divider()
            }
            Text("New sign-in").font(.subheadline).foregroundStyle(.secondary)
            if let plan = self.plan {
                HStack {
                    Button(self.provider == .codex ? "Sign In with ChatGPT…" : "Sign In with Claude…") {
                        do { try self.session.start(plan) } catch { self.error = error.localizedDescription }
                    }
                    .disabled(self.session.running)
                    if self.provider == .codex {
                        Button("Choose auth.json…") { self.pickFile() }.disabled(self.session.running)
                    }
                }
                Text(self.provider == .codex
                    ? "Opens your browser. The sign-in is saved in its own folder, never in Keychain."
                    : "Opens your browser through OMP, which keeps the sign-in.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Command") {
                    Text(plan.command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            } else {
                Text(self.unavailable ?? "Looking for \(self.provider == .codex ? "codex" : "omp")…")
                    .font(.caption).foregroundStyle(self.unavailable == nil ? Color.secondary : Color.red)
            }
            if self.session.running {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser.").font(.caption)
                    Spacer()
                    Button("Cancel") { self.session.cancel() }
                }
                HStack {
                    SecureField("Code, if asked", text: self.$answer).onSubmit { self.send() }
                    Button("Send") { self.send() }.disabled(self.answer.isEmpty)
                }
            }
            ForEach(self.session.candidates) { candidate in
                HStack {
                    PrivateText(text: candidate.identityHint, name: "email address")
                    Spacer()
                    Button("Add") { self.enroll(candidate) }
                }
            }
            if self.session.cancelled, !self.session.running, self.provider == .codex {
                Button("Use the sign-in that was saved") {
                    do { try self.session.resume() } catch { self.error = "No sign-in was saved." }
                }
            }
            if !self.session.progress.isEmpty {
                DisclosureGroup("Details") {
                    ScrollView {
                        Text(self.session.progress).font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 110)
                }
                .font(.caption)
            }
            if let error = self.error ?? self.session.error { Text(error).font(.caption).foregroundStyle(.red) }
            Spacer(minLength: 0)
            HStack { Spacer(); Button("Done") { self.dismiss() }.disabled(self.session.running) }
        }
        .padding(20).frame(width: 460).frame(minHeight: 300)
        .interactiveDismissDisabled(self.session.running)
        .task { await self.prepare() }
    }

    /// Untracked sign-ins plus removed accounts, each once.
    private var onThisMac: [(candidate: AccountCandidate, previous: String?)] {
        let config = self.store.configuration
        return self.found.filter { $0.provider == self.provider && $0.issue == nil && $0.providerAccountID != nil }
            .compactMap { candidate in
                let entry = config.accounts.first {
                    $0.provider == self.provider && $0.providerAccountID == candidate.providerAccountID
                }
                if let entry, !entry.removed { return nil }
                return (candidate, entry?.label)
            }
    }

    private func prepare() async {
        self.found = (try? AccountSettings.discover(self.store.configuration)) ?? []
        do {
            let tool = try await LoginTool.inspect(self.provider == .codex ? "codex" : "omp")
            if self.provider == .codex {
                let home = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".codex-pace-\(UUID().uuidString)")
                self.plan = AccountLoginPlan(provider: .codex, executable: tool.executable, home: home)
            } else {
                let database = try await LoginTool.localOMPDatabase(tool.executable)
                self.plan = AccountLoginPlan(provider: .claude, executable: tool.executable, database: database)
            }
        } catch {
            self.unavailable = self.provider == .codex
                ? "Codex isn't installed. Install the Codex CLI, then reopen this sheet."
                : "OMP isn't installed or doesn't use a local sign-in store. Install oh-my-pi, then reopen this sheet."
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let account = try CodexAccount.parse(Configuration.boundedRead(url.path))
            self.enroll(AccountCandidate(
                provider: .codex,
                providerAccountID: account.id,
                label: "Codex",
                source: .codexFiles(paths: [url.path], managedHome: nil),
                identityHint: account.identityHint))
        } catch { self.error = "That file doesn't contain a readable Codex sign-in." }
    }

    private func send() {
        self.session.send(self.answer)
        self.answer = ""
    }

    private func enroll(_ candidate: AccountCandidate) {
        do {
            try AccountDiscovery.revalidate(candidate)
            var config = self.store.configuration
            try config.enroll(candidate)
            try self.store.apply(config)
            self.dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

/// Removes a Codex account whose private home Pace Bar created, and signs that home out with Codex's own logout.
struct SignOutSheet: View {
    let entry: AccountEnrollment
    let identityHint: String
    let store: UsageStore
    @Environment(\.dismiss) private var dismiss
    @State private var session = AccountSignIn()
    @State private var plan: AccountLoginPlan?
    @State private var error: String?
    @State private var started = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remove and sign out \(self.entry.label)?").font(.headline)
            PrivateText(text: self.identityHint, name: "email address").foregroundStyle(.secondary)
            Text("Pace Bar stops tracking it and signs out the private Codex folder it created for this account. "
                + "Other Codex sign-ins are untouched; usage history stays.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            if let plan = self.plan {
                DisclosureGroup("Command") {
                    Text(plan.command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
            if self.session.running { ProgressView().controlSize(.small) }
            if let error = self.error ?? self.session.error { Text(error).font(.caption).foregroundStyle(.red) }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { self.dismiss() }.keyboardShortcut(.cancelAction).disabled(self.session.running)
                Button("Remove and Sign Out", role: .destructive) { self.run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(self.plan == nil || self.started)
            }
        }
        .padding(20).frame(width: 420).frame(minHeight: 200)
        .interactiveDismissDisabled(self.session.running)
        .task { await self.prepare() }
        .onChange(of: self.session.running) { _, running in
            guard !running, self.started, self.session.error == nil else { return }
            self.dismiss()
        }
    }

    private func run() {
        guard let plan = self.plan else { return }
        do {
            var config = self.store.configuration
            if let index = config.accounts.firstIndex(where: { $0.id == self.entry.id }) {
                config.accounts[index].removed = true
            }
            try self.store.apply(config)
            try self.session.start(plan)
            self.started = true
        } catch { self.error = error.localizedDescription }
    }

    private func prepare() async {
        do {
            guard case let .codexFiles(_, managedHome) = self.entry.source, let managedHome else {
                throw UsageError.message("Pace Bar didn't create this sign-in, so it won't sign it out.")
            }
            let home = Configuration.expand(managedHome)
            guard home.lastPathComponent.hasPrefix(".codex-pace-"),
                  home.deletingLastPathComponent() == FileManager.default.homeDirectoryForCurrentUser,
                  UUID(uuidString: String(home.lastPathComponent.dropFirst(".codex-pace-".count))) != nil,
                  try !(home.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink!
            else { throw UsageError.message("This folder isn't one Pace Bar created, so sign-out is blocked.") }
            let resolved = try AccountDiscovery.resolveCodex(self.entry)
            let current = try CodexAccount
                .parse(Configuration.boundedRead(home.appendingPathComponent("auth.json").path))
            guard current.id == resolved.id
            else { throw UsageError.message("That folder now holds a different account, so sign-out is blocked.") }
            let tool = try await LoginTool.inspect("codex")
            self.plan = AccountLoginPlan(
                provider: .codex,
                executable: tool.executable,
                home: home,
                logout: true,
                expectedIdentity: self.entry.providerAccountID)
        } catch { self.error = error.localizedDescription }
    }
}
