import SwiftUI
import UniformTypeIdentifiers

struct ReviewQueueView: View {
    @Bindable var viewModel: ReviewQueueViewModel
    var events: EventCenter?
    var onOpenSettings: () -> Void
    @State private var draggedViewID: UUID?
    @FocusState private var isQueryFocused: Bool
    /// Tracked width of the area below the divider (list/detail container).
    /// Drives the narrow-mode layout switch. Defaults wide so initial render
    /// uses the `HSplitView` path; the `.onGeometryChange` modifier corrects
    /// it on the first layout pass.
    @State private var availableWidth: CGFloat = 1000

    private var dashboard: DashboardViewModel { viewModel.dashboard }
    private var detail: PRDetailViewModel { viewModel.detail }

    /// Below this content width, list (350) + detail (400) + split divider
    /// can't both fit side by side. The detail pane moves below the list
    /// (vertical split) so the list never disappears.
    private static let narrowThreshold: CGFloat = 760

    private var isNarrow: Bool { availableWidth < Self.narrowThreshold }

    var body: some View {
        VStack(spacing: 0) {
            viewTabs
            queryBar
            if let events {
                EventBannerView(
                    events: events,
                    filter: \.isStanding,
                    actionFor: { err in
                        switch err {
                        case .unauthorized, .permissionDenied, .gitDirectoriesUnavailable:
                            return EventBannerView.Action(label: "Open Settings", run: onOpenSettings)
                        case .decodeCorruption(_, let backupPath?):
                            return EventBannerView.Action.revealBackup(atPath: backupPath)
                        default:
                            return nil
                        }
                    }
                )
                .padding(.horizontal, 12)
                .padding(.top, 6)
            }
            Divider()
            mainContent
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { newWidth in
                    availableWidth = newWidth
                }
        }
        // `initial` reconciles a selection that outlived this view (Settings
        // was shown, then another view was picked before returning).
        .onChange(of: dashboard.selectedViewState.pullRequests, initial: true) {
            viewModel.reconcileSelection()
        }
        .onTapGesture {
            isQueryFocused = false
        }
        .frame(minWidth: 500, minHeight: 300)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                // ⌘R lives on View › Refresh.
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    ZStack {
                        Image(systemName: "arrow.clockwise")
                            .opacity(dashboard.selectedViewState.isLoading && dashboard.selectedViewState.hasData ? 0 : 1)
                        if dashboard.selectedViewState.isLoading && dashboard.selectedViewState.hasData {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(!viewModel.canRefresh)
                .help(dashboard.selectedViewState.isLoading ? "Refreshing..." : "Refresh (⌘R)")
                .accessibilityLabel("Refresh pull requests")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    onOpenSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                .accessibilityLabel("Open Settings")
            }
        }
        .onAppear {
            viewModel.syncEditingQuery()
        }
        .task {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
            isQueryFocused = false
        }
        // Bells show whether System Settings lets them alert; the user can
        // change that there at any time.
        .task {
            await dashboard.refreshNotificationAuthorization()
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                await dashboard.refreshNotificationAuthorization()
            }
        }
        .onChange(of: isQueryFocused) {
            // Click-away without Return abandons the edit; revert the field
            // to the active query rather than displaying uncommitted text.
            if !isQueryFocused {
                viewModel.syncEditingQuery()
            }
        }
        .onKeyPress(.escape) {
            viewModel.closeDetail()
            return .handled
        }
        .alert(
            "Delete View",
            isPresented: Binding(
                get: { viewModel.viewPendingDeletion != nil },
                set: { if !$0 { viewModel.cancelDeletion() } }
            )
        ) {
            Button("Cancel", role: .cancel) { viewModel.cancelDeletion() }
            Button("Delete", role: .destructive) { viewModel.confirmDeletion() }
        } message: {
            Text("Are you sure you want to delete \"\(viewModel.viewPendingDeletion?.title ?? "")\"?")
        }
    }

    // MARK: - Subviews

    /// Routes between side-by-side (`HSplitView`) and narrow mode
    /// (`VSplitView`): when the window is too narrow for both panes, the
    /// detail moves below the list instead of replacing it, so the list
    /// stays visible and selection changes remain one click away.
    @ViewBuilder
    private var mainContent: some View {
        if isNarrow {
            VSplitView {
                contentArea
                    .frame(minHeight: 100)
                if detail.selectedPR != nil {
                    bottomDetailPane
                }
            }
        } else {
            HSplitView {
                contentArea
                    .frame(minWidth: 350)
                if detail.selectedPR != nil {
                    splitDetailPane
                }
            }
        }
    }

    private var splitDetailPane: some View {
        PRDetailView(viewModel: detail)
            .frame(minWidth: 400, maxWidth: 800)
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onChange(of: geo.size.width) { _, newWidth in
                            viewModel.detailPanelWidth = newWidth
                        }
                }
            }
            .background {
                SplitDividerRestorer(detailLength: viewModel.detailPanelWidth, clampedTo: 400...800)
            }
            // Debounce: only persist once the drag settles. The
            // task is cancelled whenever the width changes
            // again before 250ms elapse, so a live drag produces a
            // single write at drop time.
            .task(id: viewModel.detailPanelWidth) {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
                viewModel.saveDetailPanelSize()
            }
    }

    /// Narrow-mode counterpart of `splitDetailPane`: same restore/persist
    /// dance, on the vertical axis.
    private var bottomDetailPane: some View {
        PRDetailView(viewModel: detail)
            .frame(minHeight: 120)
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onChange(of: geo.size.height) { _, newHeight in
                            viewModel.detailPanelHeight = newHeight
                        }
                }
            }
            .background {
                SplitDividerRestorer(detailLength: viewModel.detailPanelHeight, clampedTo: 120...600)
            }
            .task(id: viewModel.detailPanelHeight) {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
                viewModel.saveDetailPanelSize()
            }
    }

    private var viewTabs: some View {
        // The bar-level drop delegate is the fallback that clears the drag
        // marker when a tab is released between tabs, after the last tab, or
        // on the add button — releases the per-tab delegates never see.
        // Without it the dragged tab stays at 40% opacity indefinitely.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(dashboard.views) { dashView in
                    TabButton(
                        dashView: dashView,
                        isSelected: dashView.id == dashboard.selectedViewID,
                        isDragged: draggedViewID == dashView.id,
                        draggedID: $draggedViewID,
                        viewModel: dashboard,
                        onSelect: {
                            viewModel.selectView(dashView.id)
                        },
                        onRequestDelete: {
                            viewModel.requestDeletion(of: dashView)
                        }
                    )
                }
                addButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .onDrop(of: [.text], delegate: TabDragCleanupDelegate(draggedID: $draggedViewID))
    }

    private var addButton: some View {
        Button {
            viewModel.beginAddingView()
        } label: {
            Image(systemName: "plus")
                .font(.caption)
                .padding(6)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("New view (⌘N)")
        .accessibilityLabel("New view")
        .popover(isPresented: $viewModel.isAddingView) {
            addViewPopover
        }
    }

    private var queryBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.quaternary)
            TextField("GitHub search query", text: $viewModel.editingQuery)
                .onSubmit {
                    viewModel.commitQueryEdit()
                }
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
        if let dashView = viewModel.selectedView {
            let viewID = dashView.id
            HStack(spacing: 2) {
                if dashboard.isNotificationBlocked(for: viewID) {
                    viewToggleButton(
                        icon: "bell.slash.fill",
                        isOn: true,
                        tint: .orange,
                        helpOn: "Notifications are off in System Settings. Click to turn this view's bell off.",
                        helpOff: "Enable notifications"
                    ) {
                        dashboard.setNotification(for: viewID, enabled: false)
                    }
                } else {
                    viewToggleButton(
                        icon: dashboard.isNotificationEnabled(for: viewID) ? "bell.fill" : "bell",
                        isOn: dashboard.isNotificationEnabled(for: viewID),
                        helpOn: "Disable notifications",
                        helpOff: "Enable notifications"
                    ) {
                        let on = !dashboard.isNotificationEnabled(for: viewID)
                        dashboard.setNotification(for: viewID, enabled: on)
                        if on { Task { await dashboard.ensureNotificationPermission() } }
                    }
                }

                viewToggleButton(
                    icon: "number",
                    isOn: dashboard.isBadgeEnabled(for: viewID),
                    helpOn: "Hide new PRs from menu bar",
                    helpOff: "Show new PRs in menu bar"
                ) {
                    dashboard.setBadge(for: viewID, enabled: !dashboard.isBadgeEnabled(for: viewID))
                }

                viewToggleButton(
                    icon: dashView.hideReviewed ? "eye.slash" : "eye",
                    isOn: dashView.hideReviewed,
                    helpOn: "Show reviewed PRs",
                    helpOff: "Hide reviewed PRs"
                ) {
                    dashboard.toggleHideReviewed(for: viewID)
                }
            }
        }
    }

    private func viewToggleButton(icon: String, isOn: Bool, tint: Color = .accentColor, helpOn: String, helpOff: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(isOn ? AnyShapeStyle(tint) : AnyShapeStyle(.quaternary))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOn ? helpOn : helpOff)
        .accessibilityLabel(isOn ? helpOn : helpOff)
        .accessibilityValue(isOn ? "on" : "off")
    }

    private var addViewPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New View")
                .font(.headline)

            TextField("Title", text: $viewModel.newViewTitle)
                .textFieldStyle(.roundedBorder)

            TextField("GitHub search query", text: $viewModel.newViewQuery)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))

            HStack {
                Spacer()
                Button("Cancel") { viewModel.isAddingView = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    viewModel.addView()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canAddView)
            }
        }
        .padding()
        .frame(width: 320)
    }

    private var contentArea: some View {
        Group {
            if dashboard.views.isEmpty {
                noViewsMessage
            } else {
                let state = dashboard.selectedViewState
                if state.isLoading && !state.hasData {
                    loadingView
                } else if let error = state.error, !state.hasData {
                    errorView(error, isNetworkError: state.isNetworkError)
                } else if state.isEmpty {
                    // A page can arrive fully filtered (hide-reviewed, non-PR
                    // items) while nextCursor is still set — showing "No pull
                    // requests" there is a lie; keep fetching until a page
                    // yields rows or paging genuinely ends.
                    if state.error == nil, state.canLoadMore || state.isLoadingMore {
                        loadingView
                            .id(state.nextCursor)
                            .onAppear {
                                Task { await viewModel.loadMoreIfPossible() }
                            }
                    } else {
                        emptyView
                    }
                } else {
                    listView
                }
            }
        }
        // Fallback for tab drags released over the list/detail area — the
        // per-tab drop delegates never fire there, which left the dragged
        // tab stuck at 40% opacity.
        .onDrop(of: [.text], delegate: TabDragCleanupDelegate(draggedID: $draggedViewID))
    }

    private var noViewsMessage: some View {
        VStack(spacing: 12) {
            Image(systemName: "plus.rectangle.on.rectangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No views yet")
                .font(.headline)
            Text("Click + to create a view from a GitHub search query, or start from a preset view in Settings.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            HStack {
                Button("New View…") {
                    viewModel.beginAddingView()
                }
                Button("Preset Views…") {
                    onOpenSettings()
                }
            }
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
                Task { await viewModel.refresh() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyView: some View {
        let state = dashboard.selectedViewState
        let nonPullRequests = state.nonPullRequestCount
        return VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text("No pull requests")
                .font(.headline)
            if let notice = state.hiddenResultsNotice {
                Text(notice)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else if state.filteredOutCount > 0 {
                let count = state.filteredOutCount
                Text("You've reviewed \(count == 1 ? "the pull request" : "all \(count) pull requests") this view matched.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                Button("Show Reviewed") {
                    viewModel.showReviewedPullRequests()
                }
            } else if nonPullRequests > 0 {
                VStack(spacing: 4) {
                    Text("Your query matched \(nonPullRequests) non-PR \(nonPullRequests == 1 ? "item" : "items") (issues, discussions).")
                        .foregroundStyle(.secondary)
                    Text("Add `is:pr` to filter to pull requests.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            } else {
                Text("Nothing matched this view's query.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func noticeRow(icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.orange)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    /// A refresh failed while earlier rows are on screen: they stay, marked
    /// as out of date.
    private func staleResultsRow(_ error: String, since lastRefreshedAt: Date?) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(error)
                    .fixedSize(horizontal: false, vertical: true)
                if let lastRefreshedAt {
                    Text("Showing results from \(lastRefreshedAt, format: .relative(presentation: .named)).")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button("Retry") {
                Task { await viewModel.refresh() }
            }
            .controlSize(.small)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var listView: some View {
        // Memoized on the view model — repeated body evaluations within a
        // render cycle return the cached grouping in O(1).
        let grouped = dashboard.groupedSelected
        let state = dashboard.selectedViewState
        // Per-row relative timestamps tick via `RelativeTimestampText`, so the
        // outer list is NOT wrapped in a `TimelineView(.periodic)`. Wrapping
        // the whole list cascaded SwiftUI diff + layout across ~100 rows every
        // 30 s.
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let error = state.error, !state.loadMoreFailed {
                    staleResultsRow(error, since: state.lastRefreshedAt)
                }
                if let notice = state.hiddenResultsNotice {
                    noticeRow(icon: "eye.slash", notice)
                }
                ForEach(grouped, id: \.org) { orgGroup in
                    orgSection(orgGroup)
                }
                // Load-more sentinel: fires on reaching the rendered bottom,
                // whatever the grouping. `.id(nextCursor)` re-creates it per
                // page so it re-arms while still visible; no error, so a
                // failed page isn't retried in a loop.
                if state.canLoadMore, state.error == nil {
                    Color.clear
                        .frame(height: 1)
                        .id(state.nextCursor)
                        .onAppear {
                            Task { await viewModel.loadMoreIfPossible() }
                        }
                }
                if state.isLoadingMore {
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
                if let error = state.error, state.loadMoreFailed {
                    HStack(spacing: 8) {
                        Text("Couldn't load more: \(error)")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Retry") {
                            Task { await viewModel.retryLoadMore() }
                        }
                        .controlSize(.small)
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                if state.isTruncated {
                    noticeRow(
                        icon: "text.append",
                        "Showing the first \(Constants.App.maxPullRequests) results. Narrow the query to see the rest."
                    )
                }
            }
            .padding(.vertical, 4)
            .scrollTargetLayout()
        }
        .scrollPosition(id: $viewModel.listScrollAnchor)
    }

    @ViewBuilder
    private func orgSection(_ orgGroup: DashboardViewModel.OrgGroup) -> some View {
        let isOrgCollapsed = viewModel.isOrgCollapsed(orgGroup.org)
        let prCount = orgGroup.repos.reduce(0) { $0 + $1.stacks.reduce(0) { $0 + $1.totalCount } }

        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                viewModel.toggleOrg(orgGroup.org)
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
        .accessibilityLabel("\(orgGroup.org), \(prCount) pull \(prCount == 1 ? "request" : "requests")")
        .accessibilityValue(isOrgCollapsed ? "Collapsed" : "Expanded")
        .accessibilityAddTraits(.isHeader)
        .id("org:\(orgGroup.org)")
        .contextMenu {
            if isOrgCollapsed {
                Button("Expand") {
                    withAnimation { viewModel.toggleOrg(orgGroup.org) }
                }
            } else {
                Button("Collapse Repos") {
                    withAnimation { viewModel.collapseRepos(of: orgGroup) }
                }
                Button("Expand Repos") {
                    withAnimation { viewModel.expandRepos(of: orgGroup) }
                }
                Divider()
                Button("Collapse All Orgs") {
                    withAnimation { viewModel.collapseAllOrgs() }
                }
                Button("Expand All Orgs") {
                    withAnimation { viewModel.expandAllOrgs() }
                }
            }
            Divider()
            filterMenuItems(.org(orgGroup.org), label: "org \"\(orgGroup.org)\"")
        }

        if !isOrgCollapsed {
            ForEach(orgGroup.repos, id: \.repo) { repoGroup in
                repoSection(repoGroup, org: orgGroup.org)
            }
        }
    }

    @ViewBuilder
    private func repoSection(_ repoGroup: DashboardViewModel.RepoGroup, org: String) -> some View {
        let isRepoCollapsed = viewModel.isRepoCollapsed(org: org, repo: repoGroup.repo)
        let prCount = repoGroup.stacks.reduce(0) { $0 + $1.totalCount }
        let nameWithOwner = "\(org)/\(repoGroup.repo)"

        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                viewModel.toggleRepo(org: org, repo: repoGroup.repo)
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
        .accessibilityLabel("\(repoGroup.repo), \(prCount) pull \(prCount == 1 ? "request" : "requests")")
        .accessibilityValue(isRepoCollapsed ? "Collapsed" : "Expanded")
        .accessibilityAddTraits(.isHeader)
        .id("repo:\(nameWithOwner)")
        .contextMenu {
            filterMenuItems(.repo(nameWithOwner), label: "repo \"\(nameWithOwner)\"")
        }

        if !isRepoCollapsed {
            ForEach(repoGroup.stacks) { stack in
                stackView(stack)
            }
        }
    }

    /// "Filter by …" and "Exclude …", each disabled once the query has it.
    @ViewBuilder
    private func filterMenuItems(_ qualifier: SearchQualifier, label: String) -> some View {
        Button {
            viewModel.appendFilter(qualifier)
        } label: {
            SwiftUI.Label("Filter by \(label)", systemImage: "line.3.horizontal.decrease.circle")
        }
        .disabled(viewModel.isFilterApplied(qualifier))
        Button {
            viewModel.appendFilter(qualifier.excluded)
        } label: {
            SwiftUI.Label("Exclude \(label)", systemImage: "minus.circle")
        }
        .disabled(viewModel.isFilterApplied(qualifier.excluded))
    }

    @ViewBuilder
    private func stackView(_ stack: DashboardViewModel.PRStack) -> some View {
        pullRequestItem(stack.root, stackSize: stack.totalCount) {
            withAnimation(.easeInOut(duration: 0.2)) {
                viewModel.toggleStack(stack)
            }
        }

        if viewModel.isStackExpanded(stack) {
            ForEach(stack.children) { member in
                pullRequestItem(member.pullRequest, stackSize: 0, stackDepth: member.depth) {}
            }
        }
    }

    /// `stackDepth` 0 is a stack root or a standalone PR; deeper members are
    /// indented one step per level.
    private func pullRequestItem(
        _ pr: PullRequest,
        stackSize: Int,
        stackDepth: Int = 0,
        onToggleStack: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 0) {
            if stackDepth > 0 {
                HStack(spacing: 4) {
                    Rectangle()
                        .fill(.quaternary)
                        .frame(width: 2, height: 24)
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(width: 24)
                .padding(.leading, CGFloat(stackDepth - 1) * 16)
            }
            PullRequestRowView(pullRequest: pr, stackSize: stackSize, onToggleStack: onToggleStack, onFilterBy: viewModel.appendFilter) {
                Menu("Open in") {
                    Button("Browser") {
                        dashboard.openInBrowser(pr)
                    }
                    if let match = viewModel.localMatch(for: pr) {
                        ForEach(viewModel.installedEditors) { editor in
                            Button(editor.displayName) {
                                Task { await viewModel.open(pr, in: editor) }
                            }
                            .help(openInEditorHelp(match))
                        }
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
                if pr.state == .open {
                    Divider()
                    Button(pr.isDraft ? "Mark as Ready for Review" : "Convert to Draft") {
                        Task { await dashboard.setDraft(pr, isDraft: !pr.isDraft) }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(detail.selectedPR?.id == pr.id
                    ? Color.accentColor.opacity(0.15)
                    : Color.clear)
                .padding(.horizontal, 8)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            dashboard.openInBrowser(pr)
        }
        .onTapGesture {
            viewModel.toggleSelection(of: pr)
        }
        .accessibilityAddTraits(detail.selectedPR?.id == pr.id ? .isSelected : [])
        .id(pr.id)
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
/// using the previously persisted pane length. Axis-agnostic: the detail
/// pane is the trailing/bottom subview, so the divider sits at
/// (container length − detail length) along whichever axis the enclosing
/// split view uses.
private struct SplitDividerRestorer: NSViewRepresentable {
    let detailLength: Double
    let clampedTo: ClosedRange<Double>

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let length = detailLength
        let range = clampedTo
        DispatchQueue.main.async {
            guard let splitView = Self.findSplitView(from: view) else { return }
            // NSSplitView.isVertical means side-by-side panes (vertical divider).
            let containerLength = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
            guard containerLength > 0 else { return }
            let clamped = min(max(length, range.lowerBound), range.upperBound)
            splitView.setPosition(max(0, containerLength - clamped), ofDividerAt: 0)
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

// MARK: - Tab Button

/// Extracted from `ReviewQueueView` so SwiftUI only re-renders tabs whose
/// own `isSelected` / `isDragged` changes — the previous inline helper read
/// `viewModel.selectedViewID` inside the outer body, which invalidated
/// every tab on any selection change.
private struct TabButton: View {
    let dashView: DashboardView
    let isSelected: Bool
    let isDragged: Bool
    @Binding var draggedID: UUID?
    let viewModel: DashboardViewModel
    let onSelect: () -> Void
    let onRequestDelete: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Text(dashView.title)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .opacity(isDragged ? 0.4 : 1.0)
        .onDrag {
            draggedID = dashView.id
            return NSItemProvider(object: dashView.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: TabDropDelegate(
            targetID: dashView.id,
            draggedID: $draggedID,
            viewModel: viewModel
        ))
        .contextMenu {
            Button(role: .destructive, action: onRequestDelete) {
                SwiftUI.Label("Delete View", systemImage: "trash")
            }
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
        withAnimation(.easeInOut(duration: 0.2)) {
            viewModel.moveView(from: sourceID, to: targetID)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

/// Clears the drag marker for releases the per-tab delegates never see
/// (between tabs, on the add button, over the content area). The clearing
/// must NOT live in `TabDropDelegate.dropExited`: exit/enter ordering between
/// adjacent tabs is not guaranteed, and the gaps in the tab bar fire
/// `dropExited` mid-drag — clearing there would nil the marker and break
/// live reordering. `validateDrop` keeps this target inert for text drags
/// that did not originate from a tab.
private struct TabDragCleanupDelegate: DropDelegate {
    @Binding var draggedID: UUID?

    func validateDrop(info: DropInfo) -> Bool {
        draggedID != nil
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
