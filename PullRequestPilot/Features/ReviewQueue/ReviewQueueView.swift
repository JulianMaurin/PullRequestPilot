import SwiftUI
import UniformTypeIdentifiers

struct ReviewQueueView: View {
    @Bindable var viewModel: DashboardViewModel
    var onOpenSettings: () -> Void
    @State private var expandedStacks: Set<String> = []
    @State private var collapsedOrgs: Set<String> = []
    @State private var collapsedRepos: Set<String> = []
    @State private var isAddingView = false
    @State private var newViewTitle = ""
    @State private var newViewQuery = ""
    @State private var viewToDelete: DashboardView?
    @State private var showDeleteConfirmation = false
    @State private var editingQuery: String = ""
    @State private var draggedViewID: UUID?
    @FocusState private var isQueryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            viewTabs
            queryBar
            Divider()
            contentArea
        }
        .onTapGesture {
            isQueryFocused = false
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
        .onAppear {
            syncEditingQuery()
        }
        .task {
            try? await Task.sleep(for: .milliseconds(100))
            isQueryFocused = false
        }
        .onChange(of: viewModel.selectedViewID) {
            syncEditingQuery()
        }
        .alert("Delete View", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { viewToDelete = nil }
            Button("Delete", role: .destructive) {
                if let id = viewToDelete?.id {
                    viewModel.deleteView(id: id)
                    viewToDelete = nil
                }
            }
        } message: {
            Text("Are you sure you want to delete \"\(viewToDelete?.title ?? "")\"?")
        }
    }

    private func syncEditingQuery() {
        if let id = viewModel.selectedViewID,
           let dashView = viewModel.views.first(where: { $0.id == id }) {
            editingQuery = dashView.query
        }
    }

    // MARK: - Subviews

    private var viewTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(viewModel.views) { dashView in
                    tabButton(for: dashView)
                }
                addButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func tabButton(for dashView: DashboardView) -> some View {
        let isSelected = dashView.id == viewModel.selectedViewID
        return Button {
            viewModel.selectedViewID = dashView.id
        } label: {
            HStack(spacing: 4) {
                Text(dashView.title)
                if dashView.hideReviewed {
                    Image(systemName: "eye.slash")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .opacity(draggedViewID == dashView.id ? 0.4 : 1.0)
        .onDrag {
            draggedViewID = dashView.id
            return NSItemProvider(object: dashView.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: TabDropDelegate(
            targetID: dashView.id,
            draggedID: $draggedViewID,
            viewModel: viewModel
        ))
        .contextMenu {
            Button {
                viewModel.toggleHideReviewed(for: dashView.id)
            } label: {
                SwiftUI.Label(
                    dashView.hideReviewed ? "Show Reviewed PRs" : "Hide Reviewed PRs",
                    systemImage: dashView.hideReviewed ? "eye" : "eye.slash"
                )
            }
            Divider()
            Button(role: .destructive) {
                viewToDelete = dashView
                showDeleteConfirmation = true
            } label: {
                SwiftUI.Label("Delete View", systemImage: "trash")
            }
        }
    }

    private var addButton: some View {
        Button {
            newViewTitle = ""
            newViewQuery = ""
            isAddingView = true
        } label: {
            Image(systemName: "plus")
                .font(.caption)
                .padding(6)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isAddingView) {
            addViewPopover
        }
    }

    private var queryBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.quaternary)
            TextField("GitHub search query", text: $editingQuery, onCommit: {
                commitQueryEdit()
            })
            .textFieldStyle(.plain)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(isQueryFocused ? .primary : .tertiary)
            .focused($isQueryFocused)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func commitQueryEdit() {
        guard let id = viewModel.selectedViewID,
              let dashView = viewModel.views.first(where: { $0.id == id }) else { return }
        let trimmed = editingQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != dashView.query else { return }
        viewModel.updateView(DashboardView(id: dashView.id, title: dashView.title, query: trimmed, hideReviewed: dashView.hideReviewed))
        Task { await viewModel.refresh(viewID: id) }
    }

    private var addViewPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New View")
                .font(.headline)

            TextField("Title", text: $newViewTitle)
                .textFieldStyle(.roundedBorder)

            TextField("GitHub search query", text: $newViewQuery)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))

            HStack {
                Spacer()
                Button("Cancel") { isAddingView = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    addNewView()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isNewViewValid)
            }
        }
        .padding()
        .frame(width: 320)
    }

    private var isNewViewValid: Bool {
        !newViewTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !newViewQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func addNewView() {
        let title = newViewTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = newViewQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !query.isEmpty else { return }
        let newView = DashboardView(id: UUID(), title: title, query: query)
        viewModel.addView(newView)
        viewModel.selectedViewID = newView.id
        editingQuery = query
        isAddingView = false
        Task { await viewModel.refresh(viewID: newView.id) }
    }

    @ViewBuilder
    private var contentArea: some View {
        if viewModel.views.isEmpty {
            noViewsMessage
        } else {
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
    }

    private var noViewsMessage: some View {
        VStack(spacing: 12) {
            Image(systemName: "plus.rectangle.on.rectangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No views yet")
                .font(.headline)
            Text("Tap + to create a view, or use **Create Preset Views** in Settings to get started quickly.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                orgSection(orgGroup, pullRequests: pullRequests)
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
    private func orgSection(_ orgGroup: OrgGroup, pullRequests: [PullRequest]) -> some View {
        let isOrgCollapsed = collapsedOrgs.contains(orgGroup.org)
        let prCount = orgGroup.repos.reduce(0) { $0 + $1.stacks.reduce(0) { $0 + $1.totalCount } }

        Section {
            if !isOrgCollapsed {
                ForEach(orgGroup.repos, id: \.repo) { repoGroup in
                    repoSection(repoGroup, org: orgGroup.org, pullRequests: pullRequests)
                }
            }
        } header: {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isOrgCollapsed {
                        collapsedOrgs.remove(orgGroup.org)
                    } else {
                        collapsedOrgs.insert(orgGroup.org)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isOrgCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    Text(orgGroup.org)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text("\(prCount)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                if isOrgCollapsed {
                    Button("Expand") {
                        withAnimation { _ = collapsedOrgs.remove(orgGroup.org) }
                    }
                } else {
                    Button("Collapse Repos") {
                        withAnimation {
                            for repo in orgGroup.repos {
                                collapsedRepos.insert("\(orgGroup.org)/\(repo.repo)")
                            }
                        }
                    }
                    Button("Expand Repos") {
                        withAnimation {
                            for repo in orgGroup.repos {
                                _ = collapsedRepos.remove("\(orgGroup.org)/\(repo.repo)")
                            }
                        }
                    }
                    Divider()
                    Button("Collapse All Orgs") {
                        withAnimation {
                            let grouped = groupedByOrgAndRepo(viewModel.selectedViewState.pullRequests)
                            for org in grouped { collapsedOrgs.insert(org.org) }
                        }
                    }
                    Button("Expand All Orgs") {
                        withAnimation {
                            collapsedOrgs.removeAll()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func repoSection(_ repoGroup: RepoGroup, org: String, pullRequests: [PullRequest]) -> some View {
        let repoKey = "\(org)/\(repoGroup.repo)"
        let isRepoCollapsed = collapsedRepos.contains(repoKey)
        let prCount = repoGroup.stacks.reduce(0) { $0 + $1.totalCount }

        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if isRepoCollapsed {
                    collapsedRepos.remove(repoKey)
                } else {
                    collapsedRepos.insert(repoKey)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isRepoCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
                Text(repoGroup.repo)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(prCount)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 8)

        if !isRepoCollapsed {
            ForEach(repoGroup.stacks) { stack in
                stackView(stack, isLast: stack.root.id == pullRequests.last?.id)
            }
        }
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
            if let match = viewModel.localMatch(for: pr) {
                Button("Open in VS Code") {
                    viewModel.openInEditor(pr)
                }
                .help(openInEditorHelp(match))
                Button("Open in iTerm") {
                    viewModel.openInTerminal(pr)
                }
                .help(openInEditorHelp(match))
            }
            Divider()
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pr.url.absoluteString, forType: .string)
            }
            Button("Copy Branch") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pr.headRefName, forType: .string)
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

    // MARK: - Editor

    private func openInEditorHelp(_ match: LocalRepoMatch) -> String {
        switch match.matchKind {
        case .exactBranch:
            return match.path.path
        case .worktreeBranch:
            return "Worktree: \(match.path.path)"
        case .commitMatch:
            return "Commit match: \(match.path.path)"
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

// MARK: - Tab Drag & Drop

private struct TabDropDelegate: DropDelegate {
    let targetID: UUID
    @Binding var draggedID: UUID?
    let viewModel: DashboardViewModel

    func performDrop(info: DropInfo) -> Bool {
        draggedID = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let sourceID = draggedID, sourceID != targetID else { return }
        viewModel.moveView(from: sourceID, to: targetID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
