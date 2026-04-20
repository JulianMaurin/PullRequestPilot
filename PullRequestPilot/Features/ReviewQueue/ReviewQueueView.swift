import SwiftUI
import UniformTypeIdentifiers

struct ReviewQueueView: View {
    @Bindable var viewModel: DashboardViewModel
    var prDetailViewModel: PRDetailViewModel
    var events: EventCenter?
    var onOpenSettings: () -> Void
    @State private var expandedStacks: Set<String> = []
    @State private var isAddingView = false
    @State private var newViewTitle = ""
    @State private var newViewQuery = ""
    @State private var viewToDelete: DashboardView?
    @State private var showDeleteConfirmation = false
    @State private var editingQuery: String = ""
    @State private var draggedViewID: UUID?
    @FocusState private var isQueryFocused: Bool
    @AppStorage("detailPanelWidth") private var detailPanelWidth: Double = 550

    var body: some View {
        VStack(spacing: 0) {
            viewTabs
            queryBar
            if let events {
                EventBannerView(events: events) { err in
                    if case .viewerIdentityUnavailable = err { return true }
                    if case .bookmarkPruned = err { return true }
                    return false
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
            }
            Divider()
            HSplitView {
                contentArea
                    .frame(minWidth: 350)
                if prDetailViewModel.selectedPR != nil {
                    PRDetailView(viewModel: prDetailViewModel)
                        .frame(minWidth: 400, maxWidth: 800)
                        .background {
                            GeometryReader { geo in
                                Color.clear
                                    .onChange(of: geo.size.width) { _, newWidth in
                                        detailPanelWidth = newWidth
                                    }
                            }
                        }
                        .background {
                            SplitDividerRestorer(detailWidth: detailPanelWidth)
                        }
                }
            }
        }
        .onChange(of: viewModel.selectedViewState.pullRequests) {
            if let selected = prDetailViewModel.selectedPR {
                if let updated = viewModel.selectedViewState.pullRequests.first(where: { $0.id == selected.id }) {
                    prDetailViewModel.updateSelectedPR(updated)
                } else {
                    prDetailViewModel.deselect()
                }
            }
        }
        .onTapGesture {
            isQueryFocused = false
        }
        .frame(minWidth: 500, minHeight: 300)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    prDetailViewModel.deselect()
                    Task {
                        if let id = viewModel.selectedViewID {
                            await viewModel.refresh(viewID: id)
                        }
                    }
                } label: {
                    ZStack {
                        Image(systemName: "arrow.clockwise")
                            .opacity(viewModel.selectedViewState.isLoading && viewModel.selectedViewState.hasData ? 0 : 1)
                        if viewModel.selectedViewState.isLoading && viewModel.selectedViewState.hasData {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(viewModel.selectedViewState.isLoading)
                .help(viewModel.selectedViewState.isLoading ? "Refreshing..." : "Refresh")
                .keyboardShortcut("r", modifiers: .command)
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    prDetailViewModel.deselect()
                    onOpenSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
            }
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
            prDetailViewModel.deselect()
        }
        .onKeyPress(.escape) {
            prDetailViewModel.deselect()
            return .handled
        }
        .background {
            Button("") {
                prDetailViewModel.deselect()
                viewModel.selectNextView()
            }
            .keyboardShortcut("]", modifiers: .command)
            .hidden()

            Button("") {
                prDetailViewModel.deselect()
                viewModel.selectPreviousView()
            }
            .keyboardShortcut("[", modifiers: .command)
            .hidden()
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
            prDetailViewModel.deselect()
            viewModel.selectedViewID = dashView.id
        } label: {
            Text(dashView.title)
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
            prDetailViewModel.deselect()
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
            .onTapGesture { prDetailViewModel.deselect() }
            .textFieldStyle(.plain)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(isQueryFocused ? .primary : .tertiary)
            .focused($isQueryFocused)
            viewConfigIcons
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var viewConfigIcons: some View {
        if let viewID = viewModel.selectedViewID,
           let dashView = viewModel.views.first(where: { $0.id == viewID }) {
            HStack(spacing: 2) {
                viewToggleButton(
                    icon: viewModel.isNotificationEnabled(for: viewID) ? "bell.fill" : "bell",
                    isOn: viewModel.isNotificationEnabled(for: viewID),
                    helpOn: "Disable notifications",
                    helpOff: "Enable notifications"
                ) {
                    let on = !viewModel.isNotificationEnabled(for: viewID)
                    viewModel.setNotification(for: viewID, enabled: on)
                    if on { Task { await viewModel.ensureNotificationPermission(for: viewID) } }
                }

                viewToggleButton(
                    icon: "number",
                    isOn: viewModel.isBadgeEnabled(for: viewID),
                    helpOn: "Hide new PRs from menu bar",
                    helpOff: "Show new PRs in menu bar"
                ) {
                    viewModel.setBadge(for: viewID, enabled: !viewModel.isBadgeEnabled(for: viewID))
                }

                viewToggleButton(
                    icon: dashView.hideReviewed ? "eye.slash" : "eye",
                    isOn: dashView.hideReviewed,
                    helpOn: "Show reviewed PRs",
                    helpOff: "Hide reviewed PRs"
                ) {
                    viewModel.toggleHideReviewed(for: viewID)
                }
            }
        }
    }

    private func viewToggleButton(icon: String, isOn: Bool, helpOn: String, helpOff: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOn ? helpOn : helpOff)
    }

    private func commitQueryEdit() {
        guard let id = viewModel.selectedViewID else { return }
        viewModel.commitQueryEdit(viewID: id, newQuery: editingQuery)
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
            if state.isLoading && !state.hasData {
                loadingView
            } else if let error = state.error, !state.hasData {
                errorView(error, isNetworkError: state.isNetworkError)
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

    private func errorView(_ message: String, isNetworkError: Bool = false) -> some View {
        VStack(spacing: 12) {
            if isNetworkError {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("No Connection")
                    .font(.headline)
                Text("Check your internet connection and try again.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
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
        let grouped = viewModel.groupedByOrgAndRepo(pullRequests)
        return TimelineView(.periodic(from: .now, by: 30)) { context in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(grouped.enumerated()), id: \.element.org) { _, orgGroup in
                        orgSection(orgGroup, pullRequests: pullRequests, now: context.date)
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
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func orgSection(_ orgGroup: DashboardViewModel.OrgGroup, pullRequests: [PullRequest], now: Date) -> some View {
        let isOrgCollapsed = viewModel.collapsedOrgs.contains(orgGroup.org)
        let prCount = orgGroup.repos.reduce(0) { $0 + $1.stacks.reduce(0) { $0 + $1.totalCount } }

        Button {
            prDetailViewModel.deselect()
            withAnimation(.easeInOut(duration: 0.2)) {
                if isOrgCollapsed {
                    viewModel.collapsedOrgs.remove(orgGroup.org)
                } else {
                    viewModel.collapsedOrgs.insert(orgGroup.org)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contextMenu {
            if isOrgCollapsed {
                Button("Expand") {
                    withAnimation { _ = viewModel.collapsedOrgs.remove(orgGroup.org) }
                }
            } else {
                Button("Collapse Repos") {
                    withAnimation {
                        for repo in orgGroup.repos {
                            viewModel.collapsedRepos.insert("\(orgGroup.org)/\(repo.repo)")
                        }
                    }
                }
                Button("Expand Repos") {
                    withAnimation {
                        for repo in orgGroup.repos {
                            _ = viewModel.collapsedRepos.remove("\(orgGroup.org)/\(repo.repo)")
                        }
                    }
                }
                Divider()
                Button("Collapse All Orgs") {
                    withAnimation {
                        let grouped = viewModel.groupedByOrgAndRepo(viewModel.selectedViewState.pullRequests)
                        for org in grouped { viewModel.collapsedOrgs.insert(org.org) }
                    }
                }
                Button("Expand All Orgs") {
                    withAnimation {
                        viewModel.collapsedOrgs.removeAll()
                    }
                }
            }
            Divider()
            Button {
                appendFilter("org:\(orgGroup.org)")
            } label: {
                SwiftUI.Label(
                    "Filter by org \"\(orgGroup.org)\"",
                    systemImage: "line.3.horizontal.decrease.circle"
                )
            }
            .disabled(viewModel.queryContainsFilter(qualifier: "org:\(orgGroup.org)"))
        }

        if !isOrgCollapsed {
            ForEach(orgGroup.repos, id: \.repo) { repoGroup in
                repoSection(repoGroup, org: orgGroup.org, pullRequests: pullRequests, now: now)
            }
        }
    }

    @ViewBuilder
    private func repoSection(_ repoGroup: DashboardViewModel.RepoGroup, org: String, pullRequests: [PullRequest], now: Date) -> some View {
        let repoKey = "\(org)/\(repoGroup.repo)"
        let isRepoCollapsed = viewModel.collapsedRepos.contains(repoKey)
        let prCount = repoGroup.stacks.reduce(0) { $0 + $1.totalCount }

        Button {
            prDetailViewModel.deselect()
            withAnimation(.easeInOut(duration: 0.2)) {
                if isRepoCollapsed {
                    viewModel.collapsedRepos.remove(repoKey)
                } else {
                    viewModel.collapsedRepos.insert(repoKey)
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
        .padding(.horizontal, 12)
        .padding(.leading, 8)
        .padding(.vertical, 4)
        .contextMenu {
            Button {
                appendFilter("repo:\(org)/\(repoGroup.repo)")
            } label: {
                SwiftUI.Label(
                    "Filter by repo \"\(org)/\(repoGroup.repo)\"",
                    systemImage: "line.3.horizontal.decrease.circle"
                )
            }
            .disabled(viewModel.queryContainsFilter(qualifier: "repo:\(org)/\(repoGroup.repo)"))
        }

        if !isRepoCollapsed {
            ForEach(repoGroup.stacks) { stack in
                stackView(stack, isLast: stack.root.id == pullRequests.last?.id, now: now)
            }
        }
    }

    @ViewBuilder
    private func stackView(_ stack: DashboardViewModel.PRStack, isLast: Bool, now: Date) -> some View {
        let isExpanded = expandedStacks.contains(stack.id)

        pullRequestItem(stack.root, isLast: isLast && stack.children.isEmpty, stackSize: stack.totalCount, now: now) {
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
                pullRequestItem(child, isLast: isLast && child.id == stack.children.last?.id, stackSize: 0, isStacked: true, now: now) {}
            }
        }
    }

    private func pullRequestItem(
        _ pr: PullRequest,
        isLast: Bool,
        stackSize: Int,
        isStacked: Bool = false,
        now: Date,
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
            PullRequestRowView(pullRequest: pr, stackSize: stackSize, now: now, onToggleStack: onToggleStack, onFilterBy: appendFilter) {
                Button("Open in Browser") {
                    viewModel.openInBrowser(pr)
                }
                if let match = viewModel.localMatch(for: pr) {
                    if viewModel.isVSCodeAvailable {
                        Button("Open in VS Code") {
                            viewModel.openInEditor(pr)
                        }
                        .help(openInEditorHelp(match))
                    }
                    if viewModel.isITermAvailable {
                        Button("Open in iTerm") {
                            viewModel.openInTerminal(pr)
                        }
                        .help(openInEditorHelp(match))
                    }
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
        }
        .padding(.horizontal, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(prDetailViewModel.selectedPR?.id == pr.id
                    ? Color.accentColor.opacity(0.15)
                    : Color.clear)
                .padding(.horizontal, 8)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            viewModel.openInBrowser(pr)
        }
        .onTapGesture {
            prDetailViewModel.selectPR(pr)
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

    // MARK: - Query Filters

    private func appendFilter(_ qualifier: String) {
        guard let id = viewModel.selectedViewID else { return }
        viewModel.appendFilter(viewID: id, qualifier: qualifier)
        syncEditingQuery()
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

}

// MARK: - Split Divider Restoration

/// Restores the NSSplitView divider position when the detail panel appears,
/// using the previously persisted width from @AppStorage.
private struct SplitDividerRestorer: NSViewRepresentable {
    let detailWidth: Double

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let width = detailWidth
        DispatchQueue.main.async {
            guard let splitView = Self.findSplitView(from: view),
                  splitView.bounds.width > 0 else { return }
            let clamped = min(max(width, 400), 800)
            let position = splitView.bounds.width - clamped
            splitView.setPosition(max(0, position), ofDividerAt: 0)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private static func findSplitView(from view: NSView) -> NSSplitView? {
        var current: NSView? = view
        while let candidate = current {
            if let splitView = candidate as? NSSplitView {
                return splitView
            }
            current = candidate.superview
        }
        return nil
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
        withAnimation(.easeInOut(duration: 0.2)) {
            viewModel.moveView(from: sourceID, to: targetID)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
