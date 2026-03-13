import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let appIcon = NSImage(named: "AppIcon") {
                appIcon.size = NSSize(width: 18, height: 18)
                button.image = appIcon
            } else {
                button.image = NSImage(systemSymbolName: "list.bullet.rectangle", accessibilityDescription: "Pull Request Pilot")
            }
            button.action = #selector(statusBarButtonClicked)
            button.target = self
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showWindow()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func statusBarButtonClicked() {
        showWindow()
    }

    private func showWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        // Find an existing content window (not the status bar window)
        if let window = NSApplication.shared.windows.first(where: { $0.canBecomeKey }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
