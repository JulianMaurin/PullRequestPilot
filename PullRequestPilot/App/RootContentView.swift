import SwiftUI

// MARK: - Content View

struct RootContentView: View {
    let reviewQueue: ReviewQueueViewModel
    let settingsViewModel: SettingsViewModel
    let events: EventCenter
    /// True when the app launched without a saved token — stays true until "Get Started" is clicked.
    @State private var needsInitialSetup: Bool

    private var dashboardViewModel: DashboardViewModel { reviewQueue.dashboard }

    init(reviewQueue: ReviewQueueViewModel, settingsViewModel: SettingsViewModel, events: EventCenter) {
        self.reviewQueue = reviewQueue
        self.settingsViewModel = settingsViewModel
        self.events = events
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
                    viewModel: reviewQueue,
                    events: events,
                    onOpenSettings: {
                        dashboardViewModel.showingSettings = true
                    }
                )
                .navigationTitle("PR Views")
            }
        }
        .onChange(of: settingsViewModel.hasSavedToken) { _, hasSaved in
            // Sign-out or a revoked token: nothing can fetch until a new token
            // validates, and the open PR may belong to the previous account.
            if !hasSaved {
                needsInitialSetup = true
                dashboardViewModel.showingSettings = false
                dashboardViewModel.stopAutoRefresh()
                reviewQueue.closeDetail()
            }
            // When `hasSaved` flips to true, IdentityActor.swap has already
            // refreshed the viewer login atomically — nothing else to do here.
        }
    }
}
