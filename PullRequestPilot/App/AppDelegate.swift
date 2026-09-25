import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Created with the delegate, before any window, so the status item and
    /// the menus work while the window is hidden. nil under unit tests, which
    /// host the app without running it.
    let appState: AppState?
    private var statusItem: NSStatusItem?
    /// A login launch starts in the menu bar only; the status item opens the
    /// window.
    private var hidesWindowAtLaunch = false

    override init() {
        appState = NSClassFromString("XCTestCase") == nil ? AppState() : nil
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        PullRequestStateIconView.prewarmIconCache()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            // A template image follows the menu bar's appearance (light, dark,
            // tinted, and the selected state).
            let image = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: "Pull Request Pilot")
            image?.isTemplate = true
            button.image = image
            button.setAccessibilityTitle("Pull Request Pilot")
            button.toolTip = "Pull Request Pilot"
            button.imagePosition = .imageLeading
            button.action = #selector(statusBarButtonClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        appState?.dashboardViewModel.onBadgeCountChanged = { [weak self] count in
            self?.updateStatusBarBadge(count)
        }
        updateStatusBarBadge(appState?.dashboardViewModel.badgeCount ?? 0)

        // The launch event is only readable while it's being handled.
        hidesWindowAtLaunch = Self.wasLaunchedAsLoginItem()
        if let window = mainWindow {
            mainWindowDidAppear(window)
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

    /// Called once the main window exists, which can be before or after
    /// launching finishes.
    func mainWindowDidAppear(_ window: NSWindow) {
        guard hidesWindowAtLaunch else { return }
        hidesWindowAtLaunch = false
        window.orderOut(nil)
    }

    private static func wasLaunchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication
        else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let route = NotificationRoute(userInfo: response.notification.request.content.userInfo)
        Task { @MainActor in
            if let route {
                appState?.reviewQueueViewModel.showNotification(route)
            }
            showWindow()
        }
        completionHandler()
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

        if let viewModel = appState?.dashboardViewModel {
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
        selectView(viewID)
    }

    /// Switches to a view and brings the window forward. A view that no
    /// longer exists (a stale deep link) changes nothing but the window.
    func selectView(_ viewID: UUID) {
        appState?.reviewQueueViewModel.showView(viewID)
        showWindow()
    }

    // MARK: - Status Bar Badge

    private func updateStatusBarBadge(_ count: Int) {
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

    private var mainWindow: NSWindow? {
        NSApplication.shared.windows.first(where: { $0.identifier?.rawValue == "main" })
            ?? NSApplication.shared.windows.first(where: { $0.canBecomeKey && $0.title == "Pull Request Pilot" })
    }

    func showWindow() {
        if let window = mainWindow {
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.makeKeyAndOrderFront(nil)
        }
        NSApplication.shared.activate()
        appState?.dashboardViewModel.markBadgeAsSeenForSelectedView()
    }
}
