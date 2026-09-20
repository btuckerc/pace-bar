import AppKit
import SwiftUI
import UsageBarCore

@main @MainActor
enum Main {
    static func main() {
        let app = NSApplication.shared
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-preview" {
            do { try Preview.render(to: CommandLine.arguments[2]) } catch { fputs("Preview failed\n", stderr) }
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = UsageStore()
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.item = item
        item.button?.image = UsageIcon.image()
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "Usage Bar — Codex, OpenRouter, nous"
        item.button?.target = self
        item.button?.action = #selector(self.togglePopover)
        self.popover.behavior = .transient
        self.popover.animates = false
        self.popover.delegate = self
        self.store.start()
        let center = NSWorkspace.shared.notificationCenter
        let sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main)
        { [weak self] _ in
            Task { @MainActor in self?.store.sleep() }
        }
        let wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main)
        { [weak self] _ in
            Task { @MainActor in self?.store.wake() }
        }
        self.observers = [sleepObserver, wakeObserver]
    }

    @objc private func togglePopover() {
        if self.popover.isShown {
            self.popover.performClose(nil)
            return
        }
        guard let button = self.item?.button else { return }
        self.store.refresh()
        let view = Dashboard(store: self.store, openSettings: { [weak self] in self?.showSettings() })
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        self.popover.contentViewController = hosting
        self.popover.contentSize = hosting.view.fittingSize
        self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        self.popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_: Notification) {
        // Release the SwiftUI tree between visits; data stays in the small store.
        self.popover.contentViewController = nil
    }

    private func showSettings() {
        self.popover.performClose(nil)
        if let window = self.settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 390),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Usage Bar Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(store: self.store))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }
}
