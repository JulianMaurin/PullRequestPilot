import SwiftUI

@main
struct GitHubDashboardApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: appState.reviewQueueViewModel)
        }
        .defaultSize(width: 700, height: 500)

        Settings {
            SettingsView(viewModel: appState.settingsViewModel)
        }
    }
}
