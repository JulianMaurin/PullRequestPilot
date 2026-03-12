import SwiftUI

struct ContentView: View {
    let dashboardViewModel: DashboardViewModel
    let settingsViewModel: SettingsViewModel
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            if showingSettings || !settingsViewModel.hasToken {
                SettingsView(viewModel: settingsViewModel)
                    .navigationTitle("Settings")
                    .toolbar {
                        if settingsViewModel.hasToken {
                            ToolbarItem(placement: .automatic) {
                                Button {
                                    showingSettings = false
                                    dashboardViewModel.reloadViews()
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .help("Close Settings")
                            }
                        }
                    }
            } else {
                ReviewQueueView(viewModel: dashboardViewModel, onOpenSettings: {
                    showingSettings = true
                })
                .navigationTitle(dashboardViewModel.views.first(where: { $0.id == dashboardViewModel.selectedViewID })?.title ?? "Dashboard")
            }
        }
    }
}
