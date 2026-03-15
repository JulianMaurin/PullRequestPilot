import SwiftUI

struct ContentView: View {
    let dashboardViewModel: DashboardViewModel
    let prDetailViewModel: PRDetailViewModel
    let settingsViewModel: SettingsViewModel
    @State private var showingSettings = false
    /// True when the app launched without a saved token — stays true until "Get Started" is clicked.
    @State private var needsInitialSetup: Bool

    init(dashboardViewModel: DashboardViewModel, prDetailViewModel: PRDetailViewModel, settingsViewModel: SettingsViewModel) {
        self.dashboardViewModel = dashboardViewModel
        self.prDetailViewModel = prDetailViewModel
        self.settingsViewModel = settingsViewModel
        self._needsInitialSetup = State(initialValue: !settingsViewModel.hasSavedToken)
    }

    var body: some View {
        NavigationStack {
            if showingSettings || needsInitialSetup {
                SettingsView(
                    viewModel: settingsViewModel,
                    dashboardViewModel: dashboardViewModel,
                    isInitialSetup: needsInitialSetup,
                    onDismiss: {
                        needsInitialSetup = false
                        showingSettings = false
                    }
                )
                    .navigationTitle("Settings")
                    .toolbar {
                        if showingSettings && !needsInitialSetup {
                            ToolbarItem(placement: .automatic) {
                                Button {
                                    showingSettings = false
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .help("Close Settings")
                            }
                        }
                    }
            } else {
                ReviewQueueView(viewModel: dashboardViewModel, prDetailViewModel: prDetailViewModel, onOpenSettings: {
                    showingSettings = true
                })
                .navigationTitle("")
            }
        }
        .onChange(of: settingsViewModel.hasSavedToken) { _, hasSaved in
            if !hasSaved {
                needsInitialSetup = true
                showingSettings = false
            }
        }
    }
}
