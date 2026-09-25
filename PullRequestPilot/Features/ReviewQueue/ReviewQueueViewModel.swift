import Foundation

/// State and actions for the review queue screen: view tabs, the query bar,
/// the grouped pull-request list and the detail pane.
///
/// Every change of view goes through here and ends in
/// `selectedViewDidChange()`, so the query bar and the detail pane follow
/// the selection from one place.
@MainActor
@Observable
final class ReviewQueueViewModel {
    let dashboard: DashboardViewModel
    let detail: PRDetailViewModel

    /// The query bar's text: committed on Return, reverted on click-away.
    var editingQuery = ""

    var isAddingView = false
    var newViewTitle = ""
    var newViewQuery = ""

    /// The view waiting for the user to confirm its deletion.
    var viewPendingDeletion: ViewDefinition?

    private(set) var expandedStackIDs: Set<String> = []

    /// Size of the detail pane beside the list (width) or below it (height).
    var detailPanelWidth: Double
    var detailPanelHeight: Double

    /// The list row kept in view when the layout switches between side by
    /// side and stacked, which rebuilds the list.
    var listScrollAnchor: String?

    private let editorLauncher: ExternalEditorLauncher
    private let defaults: UserDefaults

    init(dashboard: DashboardViewModel, detail: PRDetailViewModel, editorLauncher: ExternalEditorLauncher, defaults: UserDefaults) {
        self.dashboard = dashboard
        self.detail = detail
        self.editorLauncher = editorLauncher
        self.defaults = defaults
        let storedWidth = defaults.double(forKey: Constants.UserDefaultsKeys.detailPanelWidth)
        detailPanelWidth = storedWidth > 0 ? storedWidth : 550
        let storedHeight = defaults.double(forKey: Constants.UserDefaultsKeys.detailPanelHeight)
        detailPanelHeight = storedHeight > 0 ? storedHeight : 300
        syncEditingQuery()
    }

    var selectedView: ViewDefinition? {
        dashboard.views.first { $0.id == dashboard.selectedViewID }
    }

    // MARK: - Views

    func selectView(_ id: UUID) {
        guard dashboard.views.contains(where: { $0.id == id }) else { return }
        dashboard.selectedViewID = id
        selectedViewDidChange()
    }

    func selectNextView() {
        dashboard.selectNextView()
        selectedViewDidChange()
    }

    func selectPreviousView() {
        dashboard.selectPreviousView()
        selectedViewDidChange()
    }

    /// Brings a view forward from outside the list (status menu, Window menu,
    /// deep link). Returns false, changing nothing, when the view no longer
    /// exists.
    @discardableResult
    func showView(_ id: UUID) -> Bool {
        guard dashboard.views.contains(where: { $0.id == id }) else { return false }
        dashboard.showingSettings = false
        selectView(id)
        return true
    }

    /// Opens what a notification announced: its view, and the pull request
    /// when there was one and the list still has it.
    @discardableResult
    func showNotification(_ route: NotificationRoute) -> Bool {
        guard showView(route.viewID) else { return false }
        if let pullRequestID = route.pullRequestID,
           let pr = dashboard.selectedViewState.pullRequests.first(where: { $0.id == pullRequestID }) {
            detail.selectPR(pr)
        }
        return true
    }

    func beginAddingView() {
        newViewTitle = ""
        newViewQuery = ""
        dashboard.showingSettings = false
        isAddingView = true
    }

    var canAddView: Bool {
        !newViewTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !newViewQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func addView() {
        guard canAddView else { return }
        let view = ViewDefinition(
            id: UUID(),
            title: newViewTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            query: newViewQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        dashboard.addViewAndRefresh(view)
        isAddingView = false
        selectView(view.id)
    }

    func requestDeletion(of view: ViewDefinition) {
        viewPendingDeletion = view
    }

    func requestDeletionOfSelectedView() {
        dashboard.showingSettings = false
        viewPendingDeletion = selectedView
    }

    func confirmDeletion() {
        guard let view = viewPendingDeletion else { return }
        viewPendingDeletion = nil
        let wasSelected = view.id == dashboard.selectedViewID
        dashboard.deleteView(id: view.id)
        if wasSelected {
            selectedViewDidChange()
        }
    }

    func cancelDeletion() {
        viewPendingDeletion = nil
    }

    // MARK: - Query

    func syncEditingQuery() {
        if let view = selectedView {
            editingQuery = view.query
        }
    }

    /// The view model rejects empty and unchanged queries; either way the
    /// field goes back to showing the active query.
    func commitQueryEdit() {
        guard let id = dashboard.selectedViewID else { return }
        dashboard.commitQueryEdit(viewID: id, newQuery: editingQuery)
        syncEditingQuery()
    }

    func appendFilter(_ qualifier: SearchQualifier) {
        guard let id = dashboard.selectedViewID else { return }
        dashboard.appendFilter(viewID: id, qualifier: qualifier)
        syncEditingQuery()
    }

    func isFilterApplied(_ qualifier: SearchQualifier) -> Bool {
        selectedView.map { SearchQuery($0.query).contains(qualifier) } ?? false
    }

    // MARK: - Loading

    /// Reloads the selected view, and the open pull request's detail with it.
    func refresh() async {
        detail.refresh()
        guard let id = dashboard.selectedViewID else { return }
        await dashboard.refresh(viewID: id)
    }

    var canRefresh: Bool {
        selectedView != nil && !dashboard.selectedViewState.isLoading
    }

    /// Fetches the next page when the list reaches its end. Waits after a
    /// failure: retrying on every appearance would loop while offline.
    func loadMoreIfPossible() async {
        let state = dashboard.selectedViewState
        guard state.canLoadMore, state.error == nil, let id = dashboard.selectedViewID else { return }
        await dashboard.loadMore(viewID: id)
    }

    func retryLoadMore() async {
        guard dashboard.selectedViewState.canLoadMore, let id = dashboard.selectedViewID else { return }
        await dashboard.loadMore(viewID: id)
    }

    func showReviewedPullRequests() {
        guard let view = selectedView, view.hideReviewed else { return }
        dashboard.toggleHideReviewed(for: view.id)
    }

    // MARK: - Detail

    func toggleSelection(of pr: PullRequest) {
        detail.selectPR(pr)
    }

    func closeDetail() {
        detail.deselect()
    }

    /// Keeps the detail pane in step with the list: it follows the open pull
    /// request's updates and closes when the list no longer has it.
    func reconcileSelection() {
        guard let selected = detail.selectedPR else { return }
        if let updated = dashboard.selectedViewState.pullRequests.first(where: { $0.id == selected.id }) {
            detail.updateSelectedPR(updated)
        } else {
            detail.deselect()
        }
    }

    // MARK: - Local checkout

    var installedEditors: [ExternalEditor] {
        editorLauncher.installedEditors
    }

    func localMatch(for pr: PullRequest) -> LocalRepoMatch? {
        dashboard.localMatch(for: pr)
    }

    func open(_ pr: PullRequest, in editor: ExternalEditor) async {
        guard let match = dashboard.localMatch(for: pr) else { return }
        await editorLauncher.open(match.path, in: editor)
    }

    func saveDetailPanelSize() {
        defaults.set(detailPanelWidth, forKey: Constants.UserDefaultsKeys.detailPanelWidth)
        defaults.set(detailPanelHeight, forKey: Constants.UserDefaultsKeys.detailPanelHeight)
    }

    // MARK: - Groups

    func isStackExpanded(_ stack: PRGrouping.PRStack) -> Bool {
        expandedStackIDs.contains(stack.id)
    }

    func toggleStack(_ stack: PRGrouping.PRStack) {
        guard stack.totalCount > 1 else { return }
        if expandedStackIDs.contains(stack.id) {
            expandedStackIDs.remove(stack.id)
        } else {
            expandedStackIDs.insert(stack.id)
        }
    }

    func isOrgCollapsed(_ org: String) -> Bool {
        dashboard.collapsedOrgs.contains(org)
    }

    func isRepoCollapsed(org: String, repo: String) -> Bool {
        dashboard.collapsedRepos.contains(Self.repoKey(org: org, repo: repo))
    }

    /// Collapsing the group that holds the open pull request closes its
    /// detail: the highlighted row is gone.
    func toggleOrg(_ org: String) {
        if dashboard.collapsedOrgs.remove(org) == nil {
            dashboard.collapsedOrgs.insert(org)
            closeDetailIfHidden(by: { $0.repository.owner == org })
        }
    }

    func toggleRepo(org: String, repo: String) {
        let key = Self.repoKey(org: org, repo: repo)
        if dashboard.collapsedRepos.remove(key) == nil {
            dashboard.collapsedRepos.insert(key)
            closeDetailIfHidden(by: { $0.repository.nameWithOwner == key })
        }
    }

    func collapseRepos(of group: PRGrouping.OrgGroup) {
        dashboard.collapsedRepos.formUnion(group.repos.map { Self.repoKey(org: group.org, repo: $0.repo) })
        closeDetailIfHidden(by: { $0.repository.owner == group.org })
    }

    func expandRepos(of group: PRGrouping.OrgGroup) {
        dashboard.collapsedRepos.subtract(group.repos.map { Self.repoKey(org: group.org, repo: $0.repo) })
    }

    func collapseAllOrgs() {
        dashboard.collapsedOrgs.formUnion(dashboard.groupedSelected.map(\.org))
        closeDetailIfHidden(by: { _ in true })
    }

    func expandAllOrgs() {
        dashboard.collapsedOrgs.removeAll()
    }

    // MARK: - Private

    private func selectedViewDidChange() {
        detail.deselect()
        syncEditingQuery()
    }

    private func closeDetailIfHidden(by isHidden: (PullRequest) -> Bool) {
        if let selected = detail.selectedPR, isHidden(selected) {
            detail.deselect()
        }
    }

    private static func repoKey(org: String, repo: String) -> String {
        "\(org)/\(repo)"
    }
}
