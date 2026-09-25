import SwiftUI

@main
struct PullRequestPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    private var appState: AppState? { appDelegate.appState }
    private var reviewQueue: ReviewQueueViewModel? { appState?.reviewQueueViewModel }

    var body: some Scene {
        Window("Pull Request Pilot", id: "main") {
            if let appState {
                RootContentView(
                    reviewQueue: appState.reviewQueueViewModel,
                    settingsViewModel: appState.settingsViewModel,
                    events: appState.events
                )
                .background(WindowAccessor(onWindowFound: appDelegate.mainWindowDidAppear))
                // Anchor toasts at the Window scene root, not inside
                // NavigationStack — the navigation frame shifts between
                // windowed and fullscreen modes, this rect is stable.
                .overlay(alignment: .top) {
                    ToastOverlay(events: appState.events)
                }
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
            }
        }
        .defaultSize(width: 700, height: 500)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appState?.dashboardViewModel.showingSettings = true
                    appDelegate.showWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("New View…") {
                    reviewQueue?.beginAddingView()
                    appDelegate.showWindow()
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(reviewQueue == nil)
                // No shortcut: ⌘⌫ would also fire while editing the query.
                Button("Delete View…") {
                    reviewQueue?.requestDeletionOfSelectedView()
                    appDelegate.showWindow()
                }
                .disabled(reviewQueue?.selectedView == nil)
            }
            CommandGroup(before: .toolbar) {
                Button("Refresh") {
                    if let reviewQueue {
                        Task { await reviewQueue.refresh() }
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!(reviewQueue?.canRefresh ?? false))
                Button("Show Next View") {
                    reviewQueue?.selectNextView()
                }
                .keyboardShortcut("]", modifiers: .command)
                .disabled((appState?.dashboardViewModel.views.count ?? 0) < 2)
                Button("Show Previous View") {
                    reviewQueue?.selectPreviousView()
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled((appState?.dashboardViewModel.views.count ?? 0) < 2)
                Divider()
            }
            CommandGroup(replacing: .windowList) {
                if let viewModel = appState?.dashboardViewModel, !viewModel.views.isEmpty {
                    ForEach(Array(viewModel.views.enumerated()), id: \.element.id) { index, view in
                        let count = viewModel.viewStates[view.id]?.pullRequests.count ?? 0
                        if index < 9 {
                            Button("\(view.title) (\(count))") {
                                appDelegate.selectView(view.id)
                            }
                            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                        } else {
                            Button("\(view.title) (\(count))") {
                                appDelegate.selectView(view.id)
                            }
                        }
                    }
                } else {
                    Button("Show Pull Requests") {
                        appDelegate.showWindow()
                    }
                    .keyboardShortcut("0", modifiers: .command)
                }
            }
            // Replaces the system "Pull Request Pilot Help" item: without a
            // Help Book it only shows "Help isn't available", which App Review
            // treats as a broken feature.
            CommandGroup(replacing: .help) {
                Link("Pull Request Pilot Support", destination: Constants.URLs.support)
                Divider()
                Button("Export Logs\u{2026}") {
                    if let service = appState?.logExportService {
                        Task { await service.exportLogs() }
                    }
                }
                .disabled(appState == nil)

                Button("Open Console") {
                    if let service = appState?.logExportService {
                        Task { await service.openConsole() }
                    }
                }
                .disabled(appState == nil)
            }
        }
    }
}

// MARK: - URL Handling

/// Parsed `pullrequestpilot://` deep link.
///
/// Routing is allowlist-only: the scheme is registered system-wide, so any
/// host not matched here must be ignored — a passthrough that forwards a
/// caller-supplied URL to NSWorkspace would let external apps open arbitrary
/// files and URL handlers through this app (confused deputy).
enum DeepLinkRoute: Equatable {
    /// pullrequestpilot://view/<viewID>
    case selectView(UUID)

    static func route(for url: URL) -> DeepLinkRoute? {
        guard url.scheme == "pullrequestpilot",
              url.host == "view",
              let viewID = url.pathComponents.dropFirst().first,
              let uuid = UUID(uuidString: viewID)
        else { return nil }
        return .selectView(uuid)
    }
}

extension PullRequestPilotApp {
    private func handleIncomingURL(_ url: URL) {
        guard case .selectView(let uuid)? = DeepLinkRoute.route(for: url) else { return }
        appDelegate.selectView(uuid)
    }
}

// MARK: - Window close → hide

/// Finds the hosting NSWindow and overrides close behavior to hide instead of destroy.
/// Forwards all other delegate messages to SwiftUI's original delegate.
private struct WindowAccessor: NSViewRepresentable {
    let onWindowFound: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let onWindowFound = self.onWindowFound
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.originalDelegate = window.delegate
            window.delegate = context.coordinator
            onWindowFound(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSWindowDelegate {
        weak var originalDelegate: NSWindowDelegate?
        /// Hiding a full-screen window leaves its empty Space behind, so a
        /// close in full screen exits full screen first and hides after.
        private var hidesAfterExitingFullScreen = false

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if sender.styleMask.contains(.fullScreen) {
                hidesAfterExitingFullScreen = true
                sender.toggleFullScreen(nil)
            } else {
                sender.orderOut(nil)
            }
            return false
        }

        func windowDidExitFullScreen(_ notification: Notification) {
            originalDelegate?.windowDidExitFullScreen?(notification)
            guard hidesAfterExitingFullScreen, let window = notification.object as? NSWindow else { return }
            hidesAfterExitingFullScreen = false
            window.orderOut(nil)
        }

        func windowDidResize(_ notification: Notification) {
            originalDelegate?.windowDidResize?(notification)
        }

        func windowDidMove(_ notification: Notification) {
            originalDelegate?.windowDidMove?(notification)
        }

        func windowDidBecomeKey(_ notification: Notification) {
            originalDelegate?.windowDidBecomeKey?(notification)
        }

        func windowDidResignKey(_ notification: Notification) {
            originalDelegate?.windowDidResignKey?(notification)
        }

        override func responds(to aSelector: Selector!) -> Bool {
            if super.responds(to: aSelector) { return true }
            return originalDelegate?.responds(to: aSelector) ?? false
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if let original = originalDelegate, original.responds(to: aSelector) {
                return original
            }
            return super.forwardingTarget(for: aSelector)
        }
    }
}
