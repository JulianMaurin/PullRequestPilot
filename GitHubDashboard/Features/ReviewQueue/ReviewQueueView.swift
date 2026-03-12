import SwiftUI

struct ReviewQueueView: View {
    @Bindable var viewModel: DashboardViewModel
    var onOpenSettings: () -> Void

    var body: some View {
        Group {
            let state = viewModel.selectedViewState
            if state.isLoading {
                loadingView
            } else if let error = state.error {
                errorView(error)
            } else if state.isEmpty {
                emptyView
            } else {
                listView(state.pullRequests)
            }
        }
        .frame(minWidth: 500, minHeight: 300)
        .toolbar {
            if viewModel.views.count > 1 {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $viewModel.selectedViewID) {
                        ForEach(viewModel.views) { view in
                            Text(view.title).tag(Optional(view.id))
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 400)
                }
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    Task {
                        if let id = viewModel.selectedViewID {
                            await viewModel.refresh(viewID: id)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
                .keyboardShortcut("r", modifiers: .command)
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    onOpenSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
            }
        }
        .task {
            viewModel.startAutoRefresh()
        }
        .onDisappear {
            viewModel.stopAutoRefresh()
        }
    }

    // MARK: - Subviews

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading pull requests...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Retry") {
                Task {
                    if let id = viewModel.selectedViewID {
                        await viewModel.refresh(viewID: id)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text("No pull requests")
                .font(.headline)
            Text("Nothing matched this view's query.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func listView(_ pullRequests: [PullRequest]) -> some View {
        List {
            ForEach(pullRequests) { pr in
                PullRequestRow(pullRequest: pr)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        viewModel.openInBrowser(pr)
                    }
                    .contextMenu {
                        Button("Open in Browser") {
                            viewModel.openInBrowser(pr)
                        }
                        Button("Copy URL") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(pr.url.absoluteString, forType: .string)
                        }
                    }
                    .onAppear {
                        if pr.id == pullRequests.last?.id, viewModel.selectedViewState.canLoadMore {
                            Task {
                                if let id = viewModel.selectedViewID {
                                    await viewModel.loadMore(viewID: id)
                                }
                            }
                        }
                    }
            }
            if viewModel.selectedViewState.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading more...")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Spacer()
                }
                .padding(.vertical, 8)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }
}
