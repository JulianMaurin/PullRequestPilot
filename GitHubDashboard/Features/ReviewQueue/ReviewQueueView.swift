import SwiftUI

struct ReviewQueueView: View {
    @Bindable var viewModel: DashboardViewModel
    var onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.views.count > 1 {
                viewTabs
            }
            Divider()
            contentArea
        }
        .frame(minWidth: 500, minHeight: 300)
        .toolbar {
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

    private var viewTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(viewModel.views) { view in
                    let isSelected = view.id == viewModel.selectedViewID
                    Button {
                        viewModel.selectedViewID = view.id
                    } label: {
                        Text(view.title)
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var contentArea: some View {
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
        let grouped = groupedByOrgAndRepo(pullRequests)
        return List {
            ForEach(grouped, id: \.org) { orgGroup in
                ForEach(orgGroup.repos, id: \.repo) { repoGroup in
                    Section {
                        ForEach(repoGroup.pullRequests) { pr in
                            pullRequestItem(pr, isLast: pr.id == pullRequests.last?.id)
                        }
                    } header: {
                        HStack(spacing: 4) {
                            Text(orgGroup.org)
                                .fontWeight(.semibold)
                            Text("/")
                                .foregroundStyle(.tertiary)
                            Text(repoGroup.repo)
                        }
                        .font(.caption)
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

    private func pullRequestItem(_ pr: PullRequest, isLast: Bool) -> some View {
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
                if isLast, viewModel.selectedViewState.canLoadMore {
                    Task {
                        if let id = viewModel.selectedViewID {
                            await viewModel.loadMore(viewID: id)
                        }
                    }
                }
            }
    }

    // MARK: - Grouping

    private struct OrgGroup {
        let org: String
        let repos: [RepoGroup]
    }

    private struct RepoGroup {
        let repo: String
        let pullRequests: [PullRequest]
    }

    private func groupedByOrgAndRepo(_ pullRequests: [PullRequest]) -> [OrgGroup] {
        let byOrg = Dictionary(grouping: pullRequests) { $0.repository.owner }
        return byOrg.keys.sorted().map { org in
            let orgPRs = byOrg[org]!
            let byRepo = Dictionary(grouping: orgPRs) { $0.repository.name }
            let repoGroups = byRepo.keys.sorted().map { repo in
                RepoGroup(repo: repo, pullRequests: byRepo[repo]!)
            }
            return OrgGroup(org: org, repos: repoGroups)
        }
    }
}
