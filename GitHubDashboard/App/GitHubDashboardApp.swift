import SwiftUI

@main
struct GitHubDashboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        Window("GitHub Dashboard", id: "main") {
            ContentView(
                dashboardViewModel: appState.dashboardViewModel,
                settingsViewModel: appState.settingsViewModel
            )
            .background(WindowAccessor())
        }
        .defaultSize(width: 700, height: 500)
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
