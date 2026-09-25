import AppKit
import PaceBarCore
import SwiftUI

@main @MainActor
enum Main {
    static func main() {
        let app = NSApplication.shared
        if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--render-preview" {
            do { try Preview.render(to: CommandLine.arguments[2]) } catch { fputs("Preview failed\n", stderr) }
            return
        }
        do {
            if IdentityMigration.pending() {
                Self.quitUsageBar()
                try IdentityMigration.run()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Pace Bar couldn't copy your Usage Bar data"
            alert.informativeText = "\(error)\n\nThe original Usage Bar folders were not changed."
            alert.runModal()
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }

    /// The predecessor app would keep writing its old history while the copy is taken.
    private static func quitUsageBar() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.btuckerc.UsageBar")
        running.forEach { $0.terminate() }
        for _ in 0..<50 where running.contains(where: { !$0.isTerminated }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = UsageStore()
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var lastIcon: (state: QuotaIconState, style: MenuBarIcon)?
    private var dismissalMonitors: [Any] = []

    func applicationDidFinishLaunching(_: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.item = item
        self.store.iconNeedsUpdate = { [weak self] in self?.updateIcon() }
        self.updateIcon()
        item.button?.target = self
        item.button?.action = #selector(self.togglePopover)
        // Own dismissal: a transient popover can close on the status button's mouse-down (after its content
        // resizes, e.g. revealing a cost), and the button's mouse-up action would then reopen it.
        self.popover.behavior = .applicationDefined
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

    private func updateIcon() {
        let state = self.store.quotaIconState
        let style = self.store.configuration.menuBarIcon
        guard let button = self.item?.button else { return }
        let description = state.accessibilityDescription
        let redraw = self.lastIcon?.state != state || self.lastIcon?.style != style
        if redraw {
            self.lastIcon = (state, style)
            button.image = UsageIcon.image(state, style: style)
        }
        if redraw || button.toolTip != description {
            button.image?.accessibilityDescription = description
            button.setAccessibilityLabel(description)
            button.toolTip = description
        }
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
        self.installDismissal()
    }

    func popoverDidClose(_: Notification) {
        for monitor in self.dismissalMonitors {
            NSEvent.removeMonitor(monitor)
        }
        self.dismissalMonitors = []
        // Release the SwiftUI tree between visits; data stays in the small store.
        self.popover.contentViewController = nil
    }

    /// Closes on Escape and on clicks anywhere except the popover and the status button, which toggles.
    private func installDismissal() {
        guard self.dismissalMonitors.isEmpty else { return }
        let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown])
        { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }
                self.popover.performClose(nil)
                return nil
            }
            if event.window !== self.popover.contentViewController?.view.window, !self.pointerIsOverStatusItem {
                self.popover.performClose(nil)
            }
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown])
            { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.pointerIsOverStatusItem else { return }
                    self.popover.performClose(nil)
                }
            }
        self.dismissalMonitors = [local, global].compactMap(\.self)
    }

    private var pointerIsOverStatusItem: Bool {
        guard let button = self.item?.button, let window = button.window else { return false }
        return window.convertToScreen(button.convert(button.bounds, to: nil)).contains(NSEvent.mouseLocation)
    }

    private func showSettings() {
        self.popover.performClose(nil)
        if let window = self.settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = SettingsWindow.make(store: self.store)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }
}
