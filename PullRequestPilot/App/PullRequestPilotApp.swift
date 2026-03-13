import SwiftUI

@main
struct PullRequestPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState: AppState?

    init() {
        // Skip full app initialization when running unit tests
        if NSClassFromString("XCTestCase") == nil {
            _appState = State(initialValue: AppState())
        }
    }

    var body: some Scene {
        Window("Pull Request Pilot", id: "main") {
            if let appState {
                ContentView(
                    dashboardViewModel: appState.dashboardViewModel,
                    settingsViewModel: appState.settingsViewModel
                )
                .background(WindowAccessor())
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
            }
        }
        .defaultSize(width: 700, height: 500)
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
            }
        default:
            break
        }
    }
}

// MARK: - Window close → hide

/// Finds the hosting NSWindow and overrides close behavior to hide instead of destroy.
private struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.delegate = context.coordinator
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSWindowDelegate {
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            sender.orderOut(nil)
            return false
        }
    }
}
