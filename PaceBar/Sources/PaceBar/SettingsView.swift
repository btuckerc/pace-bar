import AppKit
import PaceBarCore
import ServiceManagement
import SwiftUI

/// The standard macOS settings window: toolbar tabs, the title follows the selected pane.
@MainActor
enum SettingsWindow {
    static func make(store: UsageStore) -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = []
        for (title, symbol, view) in [
            ("Accounts", "person.crop.circle", AnyView(AccountSettings(store: store))),
            ("Hosts", "server.rack", AnyView(HostSettings(store: store))),
            ("General", "gearshape", AnyView(GeneralSettings(store: store))),
        ] {
            let pane = NSHostingController(rootView: view.frame(width: 600, height: 520))
            pane.sizingOptions = []
            pane.preferredContentSize = NSSize(width: 600, height: 520)
            pane.title = title
            let item = NSTabViewItem(viewController: pane)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        return window
    }
}

struct GeneralSettings: View {
    let store: UsageStore
    @State private var menuBarIcon = MenuBarIcon.bars
    @State private var error: String?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Picker("Menu bar icon", selection: self.$menuBarIcon) {
                    Text("Bars").tag(MenuBarIcon.bars)
                    Text("Orbit").tag(MenuBarIcon.orbit)
                }
                .onChange(of: self.menuBarIcon) { _, style in
                    guard style != self.store.configuration.menuBarIcon else { return }
                    do { try self.store.setMenuBarIcon(style) } catch { self.error = error.localizedDescription }
                }
            } footer: {
                Text("Active accounts are grouped by provider. More than six accounts use a provider summary.")
                    .font(.caption).foregroundStyle(.secondary)
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
            } footer: {
                Text("Cloud: every 5 minutes. Hosts: every minute. Slower in Low Power Mode. Pause stops all polling.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if let error = self.error { Text(error).foregroundStyle(.red) }
                Link("Source & updates", destination: URL(string: "https://github.com/btuckerc/pace-bar")!)
            }
        }
        .formStyle(.grouped)
        .onAppear { self.menuBarIcon = self.store.configuration.menuBarIcon }
    }
}
