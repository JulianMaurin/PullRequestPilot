import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var clickCount = 0
    private var clickTimer: Timer?

    /// Set by PullRequestPilotApp once AppState is available.
    var dashboardViewModel: DashboardViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self

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

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // MARK: - Status Bar Click Handling

    @objc private func statusBarButtonClicked() {
        clickCount += 1
        if clickCount == 2 {
            clickTimer?.invalidate()
            clickTimer = nil
            clickCount = 0
            showWindow()
        } else {
            clickTimer = Timer.scheduledTimer(withTimeInterval: NSEvent.doubleClickInterval, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.clickCount = 0
                    self?.showStatusMenu()
                }
            }
        }
    }

    // MARK: - Menu

    private func showStatusMenu() {
        let menu = NSMenu()

        if let viewModel = dashboardViewModel {
            if viewModel.views.isEmpty {
                let noViewsItem = NSMenuItem(title: "No views configured", action: nil, keyEquivalent: "")
                noViewsItem.isEnabled = false
                menu.addItem(noViewsItem)
            } else {
                for view in viewModel.views {
                    let count = viewModel.viewStates[view.id]?.pullRequests.count ?? 0
                    let title = "\(view.title)  (\(count))"
                    let item = NSMenuItem(title: title, action: #selector(viewMenuItemClicked(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = view.id
                    menu.addItem(item)
                }
            }
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func viewMenuItemClicked(_ sender: NSMenuItem) {
        guard let viewID = sender.representedObject as? UUID else { return }
        dashboardViewModel?.selectedViewID = viewID
        showWindow()
    }

    // MARK: - Window

    private func showWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first(where: { $0.canBecomeKey }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
