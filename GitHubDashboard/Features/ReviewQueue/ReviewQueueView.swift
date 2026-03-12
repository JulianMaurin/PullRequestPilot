import SwiftUI

struct ReviewQueueView: View {
    @Bindable var viewModel: DashboardViewModel
    var onOpenSettings: () -> Void
    @State private var expandedStacks: Set<String> = []

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
                        ForEach(repoGroup.stacks) { stack in
                            stackView(stack, isLast: stack.root.id == pullRequests.last?.id)
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

    @ViewBuilder
    private func stackView(_ stack: PRStack, isLast: Bool) -> some View {
        let isExpanded = expandedStacks.contains(stack.id)

        pullRequestItem(stack.root, isLast: isLast && stack.children.isEmpty, stackSize: stack.totalCount) {
            if stack.totalCount > 1 {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedStacks.remove(stack.id)
                    } else {
                        expandedStacks.insert(stack.id)
                    }
                }
            }
        }

        if isExpanded {
            ForEach(stack.children) { child in
                pullRequestItem(child, isLast: isLast && child.id == stack.children.last?.id, stackSize: 0, isStacked: true) {}
            }
        }
    }

    private func pullRequestItem(
        _ pr: PullRequest,
        isLast: Bool,
        stackSize: Int,
        isStacked: Bool = false,
        onToggleStack: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 0) {
            if isStacked {
                HStack(spacing: 4) {
                    Rectangle()
                        .fill(.quaternary)
                        .frame(width: 2, height: 24)
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(width: 24)
            }
            PullRequestRow(pullRequest: pr, stackSize: stackSize, onToggleStack: onToggleStack)
        }
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

    // MARK: - Stacking

    private struct PRStack: Identifiable {
        let root: PullRequest
        let children: [PullRequest]
        var id: String { root.id }
        var totalCount: Int { 1 + children.count }
    }

    // MARK: - Grouping

    private struct OrgGroup {
        let org: String
        let repos: [RepoGroup]
    }

    private struct RepoGroup {
        let repo: String
        let stacks: [PRStack]
    }

    private func groupedByOrgAndRepo(_ pullRequests: [PullRequest]) -> [OrgGroup] {
        let byOrg = Dictionary(grouping: pullRequests) { $0.repository.owner }
        return byOrg.keys.sorted().map { org in
            let orgPRs = byOrg[org]!
            let byRepo = Dictionary(grouping: orgPRs) { $0.repository.name }
            let repoGroups = byRepo.keys.sorted().map { repo in
                RepoGroup(repo: repo, stacks: buildStacks(byRepo[repo]!))
            }
            return OrgGroup(org: org, repos: repoGroups)
        }
    }

    private func buildStacks(_ pullRequests: [PullRequest]) -> [PRStack] {
        // Map head branch → PR for this repo
        let headToPR = Dictionary(uniqueKeysWithValues: pullRequests.map { ($0.headRefName, $0) })

        // A PR is a child if its base branch is another PR's head branch
        let childIDs = Set(pullRequests.compactMap { pr -> String? in
            guard headToPR[pr.baseRefName] != nil else { return nil }
            return pr.id
        })

        // Root PRs are those not stacked on another PR in the set
        let roots = pullRequests.filter { !childIDs.contains($0.id) }

        return roots.map { root in
            var children: [PullRequest] = []
            var currentHead = root.headRefName
            // Walk the chain: find PRs whose base is the current head
            while let next = pullRequests.first(where: { $0.baseRefName == currentHead && $0.id != root.id }) {
                children.append(next)
                currentHead = next.headRefName
            }
            return PRStack(root: root, children: children)
        }
    }
}
