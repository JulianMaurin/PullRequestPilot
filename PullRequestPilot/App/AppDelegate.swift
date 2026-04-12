import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem?
    /// Set by PullRequestPilotApp once AppState is available.
    var appState: AppState?
    var dashboardViewModel: DashboardViewModel? {
        didSet {
            dashboardViewModel?.onBadgeCountChanged = { [weak self] count in
                self?.updateStatusBarBadge(count)
            }
            updateStatusBarBadge(dashboardViewModel?.badgeCount ?? 0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            if let appIcon = NSImage(named: "AppIcon") {
                appIcon.size = NSSize(width: 18, height: 18)
                button.image = appIcon
            } else {
                button.image = NSImage(systemSymbolName: "list.bullet.rectangle", accessibilityDescription: "Pull Request Pilot")
            }
            button.imagePosition = .imageLeading
            button.action = #selector(statusBarButtonClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showWindow()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.cleanup()
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
        guard let event = NSApp.currentEvent else {
            showWindow()
            return
        }

        if event.modifierFlags.contains(.control) || event.type == .rightMouseUp {
            showStatusMenu()
        } else {
            showWindow()
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

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func viewMenuItemClicked(_ sender: NSMenuItem) {
        guard let viewID = sender.representedObject as? UUID else { return }
        dashboardViewModel?.selectedViewID = viewID
        showWindow()
    }

    // MARK: - Status Bar Badge

    func updateStatusBarBadge(_ count: Int) {
        guard let button = statusItem?.button else { return }
        if count > 0 {
            let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            button.attributedTitle = NSAttributedString(string: " \(count)", attributes: attrs)
        } else {
            button.attributedTitle = NSAttributedString(string: "")
        }
    }

    // MARK: - Window

    func showWindow() {
        if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == "main" || ($0.canBecomeKey && $0.title == "Pull Request Pilot") }) ?? NSApplication.shared.windows.first(where: { $0.canBecomeKey }) {
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.makeKeyAndOrderFront(nil)
        }
        NSApplication.shared.activate()
        dashboardViewModel?.markBadgeAsSeen()
    }
}
