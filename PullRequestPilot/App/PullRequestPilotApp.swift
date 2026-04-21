import SwiftUI

@main
struct PullRequestPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState: AppState?

    init() {
        // Skip full app initialization when running unit tests
        if NSClassFromString("XCTestCase") == nil {
            let state = AppState()
            _appState = State(initialValue: state)
        }
    }

    var body: some Scene {
        Window("Pull Request Pilot", id: "main") {
            if let appState {
                RootContentView(
                    dashboardViewModel: appState.dashboardViewModel,
                    prDetailViewModel: appState.prDetailViewModel,
                    settingsViewModel: appState.settingsViewModel,
                    events: appState.events,
                    userDefaults: appState.userDefaults
                )
                .background(WindowAccessor())
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
                .onAppear {
                    if appDelegate.appState == nil {
                        appDelegate.appState = appState
                        appDelegate.dashboardViewModel = appState.dashboardViewModel
                    }
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
            CommandGroup(replacing: .windowList) {
                if let viewModel = appState?.dashboardViewModel, !viewModel.views.isEmpty {
                    ForEach(Array(viewModel.views.enumerated()), id: \.element.id) { index, view in
                        let count = viewModel.viewStates[view.id]?.pullRequests.count ?? 0
                        if index < 9 {
                            Button("\(view.title) (\(count))") {
                                viewModel.showingSettings = false
                                viewModel.selectedViewID = view.id
                                appDelegate.showWindow()
                            }
                            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                        } else {
                            Button("\(view.title) (\(count))") {
                                viewModel.showingSettings = false
                                viewModel.selectedViewID = view.id
                                appDelegate.showWindow()
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
            CommandGroup(after: .help) {
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

extension PullRequestPilotApp {
    private func handleIncomingURL(_ url: URL) {
        guard url.scheme == "pullrequestpilot" else { return }

        switch url.host {
        case "pr":
            // pullrequestpilot://pr?url=<encoded-github-url>
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let prURLString = components.queryItems?.first(where: { $0.name == "url" })?.value,
               let prURL = URL(string: prURLString)
            {
                NSWorkspace.shared.open(prURL)
            }
        case "view":
            // pullrequestpilot://view/<viewID>
            if let viewID = url.pathComponents.dropFirst().first,
               let uuid = UUID(uuidString: viewID)
            {
                appState?.dashboardViewModel.selectedViewID = uuid
                appDelegate.showWindow()
            }
        default:
            break
        }
    }
}

// MARK: - Window close → hide

/// Finds the hosting NSWindow and overrides close behavior to hide instead of destroy.
/// Forwards all other delegate messages to SwiftUI's original delegate.
private struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.originalDelegate = window.delegate
            window.delegate = context.coordinator
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSWindowDelegate {
        weak var originalDelegate: NSWindowDelegate?

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            sender.orderOut(nil)
            return false
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
