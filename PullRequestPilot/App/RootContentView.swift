import SwiftUI

// MARK: - Content View

struct RootContentView: View {
    let dashboardViewModel: DashboardViewModel
    let prDetailViewModel: PRDetailViewModel
    let settingsViewModel: SettingsViewModel
    let events: EventCenter
    let userDefaults: UserDefaults
    /// True when the app launched without a saved token — stays true until "Get Started" is clicked.
    @State private var needsInitialSetup: Bool

    init(dashboardViewModel: DashboardViewModel, prDetailViewModel: PRDetailViewModel, settingsViewModel: SettingsViewModel, events: EventCenter, userDefaults: UserDefaults) {
        self.dashboardViewModel = dashboardViewModel
        self.prDetailViewModel = prDetailViewModel
        self.settingsViewModel = settingsViewModel
        self.events = events
        self.userDefaults = userDefaults
        self._needsInitialSetup = State(initialValue: !settingsViewModel.hasSavedToken)
    }

    var body: some View {
        NavigationStack {
            if dashboardViewModel.showingSettings || needsInitialSetup {
                SettingsView(
                    viewModel: settingsViewModel,
                    dashboard: dashboardViewModel,
                    events: events,
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
                                .accessibilityLabel("Close Settings")
                            }
                        }
                    }
            } else {
                ReviewQueueView(
                    viewModel: dashboardViewModel,
                    prDetailViewModel: prDetailViewModel,
                    events: events,
                    userDefaults: userDefaults,
                    onOpenSettings: {
                        dashboardViewModel.showingSettings = true
                    }
                )
                .navigationTitle("PR Views")
            }
        }
        .overlay(alignment: .top) {
            ToastOverlay(events: events)
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
