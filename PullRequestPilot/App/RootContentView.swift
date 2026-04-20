import SwiftUI

// MARK: - Content View

struct RootContentView: View {
    let dashboardViewModel: DashboardViewModel
    let prDetailViewModel: PRDetailViewModel
    let settingsViewModel: SettingsViewModel
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
            if dashboardViewModel.showingSettings || needsInitialSetup {
                SettingsView(
                    viewModel: settingsViewModel,
                    dashboard: dashboardViewModel,
                    isInitialSetup: needsInitialSetup,
                    onDismiss: {
                        needsInitialSetup = false
                        dashboardViewModel.showingSettings = false
                    }
                )
                    .navigationTitle("Settings")
                    .toolbar {
                        if dashboardViewModel.showingSettings && !needsInitialSetup {
                            ToolbarItem(placement: .automatic) {
                                Button {
                                    dashboardViewModel.showingSettings = false
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .help("Close Settings")
                            }
                        }
                    }
            } else {
                ReviewQueueView(viewModel: dashboardViewModel, prDetailViewModel: prDetailViewModel, onOpenSettings: {
                    dashboardViewModel.showingSettings = true
                })
                .navigationTitle("PR Views")
            }
        }
        .onChange(of: settingsViewModel.hasSavedToken) { _, hasSaved in
            if !hasSaved {
                needsInitialSetup = true
                dashboardViewModel.showingSettings = false
            }
            // When `hasSaved` flips to true, IdentityActor.swap has already
            // refreshed the viewer login atomically — nothing else to do here.
        }
    }
}
