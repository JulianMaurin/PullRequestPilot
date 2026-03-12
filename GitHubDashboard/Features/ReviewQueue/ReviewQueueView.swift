import SwiftUI

struct ReviewQueueView: View {
    @Bindable var viewModel: ReviewQueueViewModel

    var body: some View {
        Group {
            if viewModel.isLoading {
                loadingView
            } else if let error = viewModel.error {
                errorView(error)
            } else if viewModel.isEmpty {
                emptyView
            } else {
                listView
            }
        }
        .frame(minWidth: 500, minHeight: 300)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
                .keyboardShortcut("r", modifiers: .command)
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
                Task { await viewModel.refresh() }
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
            Text("No reviews waiting")
                .font(.headline)
            Text("You're all caught up.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var listView: some View {
        List(viewModel.pullRequests) { pr in
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
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }
}
