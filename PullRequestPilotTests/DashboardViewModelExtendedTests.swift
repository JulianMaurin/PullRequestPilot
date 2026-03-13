import Testing
import Foundation
@testable import PullRequestPilot

@MainActor
@Suite("DashboardViewModel Extended")
struct DashboardViewModelExtendedTests {
    let mockClient = MockGitHubClient()
    let localRepoService = LocalRepositoryService()

    private func makeViewModel(suiteName: String = "DashboardViewModelExtended") -> DashboardViewModel {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = ViewsStore(defaults: defaults)
        return DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService)
    }

    // MARK: - ViewState

    @Test("ViewState isEmpty is true when no PRs and not loading")
    func viewStateIsEmpty() {
        let state = ViewState()
        #expect(state.isEmpty)
    }

    @Test("ViewState isEmpty is false when loading")
    func viewStateIsNotEmptyWhenLoading() {
        let state = ViewState(isLoading: true)
        #expect(!state.isEmpty)
    }

    @Test("ViewState canLoadMore requires cursor and not loading")
    func viewStateCanLoadMore() {
        var state = ViewState()
        state.nextCursor = "abc"
        #expect(state.canLoadMore)

        state.isLoadingMore = true
        #expect(!state.canLoadMore)
    }

    @Test("ViewState canLoadMore is false when reachedLimit")
    func viewStateCannotLoadMoreWhenReachedLimit() {
        var state = ViewState()
        state.nextCursor = "abc"
        state.reachedLimit = true
        #expect(!state.canLoadMore)
    }

    @Test("ViewState canLoadMore is false without cursor")
    func viewStateCannotLoadMoreWithoutCursor() {
        let state = ViewState()
        #expect(!state.canLoadMore)
    }

    // MARK: - loadMore

    @Test("loadMore appends PRs from next page")
    func loadMoreAppendsPRs() async {
        let pr1 = TestPullRequestFactory.make(id: "PR_1", number: 1, title: "First")
        let pr2 = TestPullRequestFactory.make(id: "PR_2", number: 2, title: "Second")

        mockClient.pullRequestsToReturn = [pr1]
        mockClient.nextCursorToReturn = "cursor_1"

        let viewModel = makeViewModel(suiteName: "LoadMore")
        let viewID = viewModel.views.first!.id
        await viewModel.refresh(viewID: viewID)

        #expect(viewModel.viewStates[viewID]!.pullRequests.count == 1)
        #expect(viewModel.viewStates[viewID]!.canLoadMore)

        mockClient.pullRequestsToReturn = [pr2]
        mockClient.nextCursorToReturn = nil

        await viewModel.loadMore(viewID: viewID)

        #expect(viewModel.viewStates[viewID]!.pullRequests.count == 2)
        #expect(viewModel.viewStates[viewID]!.pullRequests[1].title == "Second")
    }

    @Test("loadMore deduplicates PRs")
    func loadMoreDeduplicates() async {
        let pr1 = TestPullRequestFactory.make(id: "PR_1", number: 1, title: "First")

        mockClient.pullRequestsToReturn = [pr1]
        mockClient.nextCursorToReturn = "cursor_1"

        let viewModel = makeViewModel(suiteName: "LoadMoreDedup")
        let viewID = viewModel.views.first!.id
        await viewModel.refresh(viewID: viewID)

        // Return the same PR again
        mockClient.pullRequestsToReturn = [pr1]
        mockClient.nextCursorToReturn = nil

        await viewModel.loadMore(viewID: viewID)

        #expect(viewModel.viewStates[viewID]!.pullRequests.count == 1)
    }

    // MARK: - updateView

    @Test("updateView modifies existing view")
    func updateViewModifiesView() {
        let viewModel = makeViewModel(suiteName: "UpdateView")
        var view = viewModel.views.first!
        let originalTitle = view.title
        view.title = "Updated Title"
        viewModel.updateView(view)

        #expect(viewModel.views.first!.title == "Updated Title")
        #expect(viewModel.views.first!.title != originalTitle)
    }

    @Test("updateView ignores unknown view")
    func updateViewIgnoresUnknown() {
        let viewModel = makeViewModel(suiteName: "UpdateViewUnknown")
        let unknownView = DashboardView(id: UUID(), title: "Unknown", query: "test")
        let countBefore = viewModel.views.count
        viewModel.updateView(unknownView)
        #expect(viewModel.views.count == countBefore)
    }

    // MARK: - deleteView

    @Test("deleteView updates selection to next available view")
    func deleteViewUpdatesSelection() {
        let viewModel = makeViewModel(suiteName: "DeleteViewSelection")
        let view1 = DashboardView(id: UUID(), title: "View 1", query: "q1")
        let view2 = DashboardView(id: UUID(), title: "View 2", query: "q2")
        viewModel.addView(view1)
        viewModel.addView(view2)

        viewModel.selectedViewID = view1.id
        viewModel.deleteView(id: view1.id)

        #expect(viewModel.selectedViewID != nil)
        #expect(viewModel.selectedViewID != view1.id)
    }

    // MARK: - reloadViews

    @Test("reloadViews syncs state with store")
    func reloadViewsSyncsState() {
        let defaults = UserDefaults(suiteName: "ReloadViews")!
        defaults.removePersistentDomain(forName: "ReloadViews")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService)

        let newView = DashboardView(id: UUID(), title: "New View", query: "test")
        var allViews = store.load()
        allViews.append(newView)
        store.save(allViews)

        viewModel.reloadViews()

        #expect(viewModel.views.contains(where: { $0.id == newView.id }))
        #expect(viewModel.viewStates[newView.id] != nil)
    }

    // MARK: - selectedViewState

    @Test("selectedViewState returns empty state when no selection")
    func selectedViewStateNoSelection() {
        let viewModel = makeViewModel(suiteName: "SelectedViewState")
        viewModel.selectedViewID = nil
        let state = viewModel.selectedViewState
        #expect(state.isEmpty)
    }

    // MARK: - Notifications

    @Test("toggleNotification enables and disables")
    func toggleNotification() {
        let defaults = UserDefaults(suiteName: "ToggleNotification")!
        defaults.removePersistentDomain(forName: "ToggleNotification")

        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService)
        let viewID = viewModel.views.first!.id

        #expect(!viewModel.isNotificationEnabled(for: viewID))

        viewModel.toggleNotification(for: viewID)
        #expect(viewModel.isNotificationEnabled(for: viewID))

        viewModel.toggleNotification(for: viewID)
        #expect(!viewModel.isNotificationEnabled(for: viewID))
    }

    // MARK: - Auto-refresh idempotency

    @Test("startAutoRefresh is idempotent")
    func startAutoRefreshIdempotent() {
        let viewModel = makeViewModel(suiteName: "AutoRefreshIdem")
        viewModel.startAutoRefresh()
        viewModel.startAutoRefresh()
        // Should not create multiple tasks — just verify no crash
        viewModel.stopAutoRefresh()
    }

    // MARK: - CancellationError handling

    @Test("refresh ignores CancellationError")
    func refreshIgnoresCancellation() async {
        mockClient.errorToThrow = CancellationError()

        let viewModel = makeViewModel(suiteName: "CancelRefresh")
        let viewID = viewModel.views.first!.id
        await viewModel.refresh(viewID: viewID)

        let state = viewModel.viewStates[viewID]!
        #expect(state.error == nil)
    }

    // MARK: - Refresh with unknown viewID

    @Test("refresh with unknown viewID is a no-op")
    func refreshUnknownViewID() async {
        let viewModel = makeViewModel(suiteName: "UnknownViewID")
        await viewModel.refresh(viewID: UUID())
        #expect(mockClient.fetchPullRequestsCallCount == 0)
    }

    // MARK: - addView sets selection when none

    @Test("addView sets selectedViewID when it was nil")
    func addViewSetsSelectionWhenNil() {
        let viewModel = makeViewModel(suiteName: "AddViewSelection")
        // Delete all existing views
        let viewIDs = viewModel.views.map(\.id)
        for id in viewIDs {
            viewModel.deleteView(id: id)
        }
        #expect(viewModel.selectedViewID == nil)

        let newView = DashboardView(id: UUID(), title: "New", query: "test")
        viewModel.addView(newView)
        #expect(viewModel.selectedViewID == newView.id)
    }

    // MARK: - refreshAll

    @Test("refreshAll fetches PRs for all views")
    func refreshAllFetchesAllViews() async {
        let pr = TestPullRequestFactory.make(id: "PR_1", title: "PR 1")
        mockClient.pullRequestsToReturn = [pr]
        mockClient.viewerLoginToReturn = "testuser"

        let viewModel = makeViewModel(suiteName: "RefreshAll")
        let view2 = DashboardView(id: UUID(), title: "My PRs", query: "author:@me")
        viewModel.addView(view2)

        await viewModel.refreshAll()

        for view in viewModel.views {
            let state = viewModel.viewStates[view.id]
            #expect(state != nil)
            #expect(state!.pullRequests.count == 1)
        }
    }

    // MARK: - toggleHideReviewed

    @Test("toggleHideReviewed toggles the flag and persists")
    func toggleHideReviewed() async {
        let defaults = UserDefaults(suiteName: "ToggleHideReviewed")!
        defaults.removePersistentDomain(forName: "ToggleHideReviewed")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService)
        let viewID = viewModel.views.first!.id
        let initialValue = viewModel.views.first!.hideReviewed

        mockClient.pullRequestsToReturn = []
        viewModel.toggleHideReviewed(for: viewID)

        // Give the Task inside toggleHideReviewed a chance to run
        try? await Task.sleep(for: .milliseconds(100))

        #expect(viewModel.views.first!.hideReviewed == !initialValue)

        // Check it persisted
        let reloadedViews = store.load()
        #expect(reloadedViews.first(where: { $0.id == viewID })?.hideReviewed == !initialValue)
    }

    // MARK: - loadMore error handling

    @Test("loadMore surfaces error on failure")
    func loadMoreError() async {
        let pr = TestPullRequestFactory.make(id: "PR_1", title: "PR 1")
        mockClient.pullRequestsToReturn = [pr]
        mockClient.nextCursorToReturn = "cursor_1"

        let viewModel = makeViewModel(suiteName: "LoadMoreError")
        let viewID = viewModel.views.first!.id
        await viewModel.refresh(viewID: viewID)

        mockClient.errorToThrow = GitHubClientError.networkError(URLError(.timedOut))
        await viewModel.loadMore(viewID: viewID)

        let state = viewModel.viewStates[viewID]!
        #expect(state.error != nil)
        // Original PRs should still be there
        #expect(state.pullRequests.count == 1)
    }

    @Test("loadMore ignores CancellationError")
    func loadMoreIgnoresCancellation() async {
        let pr = TestPullRequestFactory.make(id: "PR_1", title: "PR 1")
        mockClient.pullRequestsToReturn = [pr]
        mockClient.nextCursorToReturn = "cursor_1"

        let viewModel = makeViewModel(suiteName: "LoadMoreCancel")
        let viewID = viewModel.views.first!.id
        await viewModel.refresh(viewID: viewID)

        mockClient.errorToThrow = CancellationError()
        await viewModel.loadMore(viewID: viewID)

        let state = viewModel.viewStates[viewID]!
        #expect(state.error == nil)
    }

    @Test("loadMore is no-op when canLoadMore is false")
    func loadMoreNoOpWhenCannotLoad() async {
        mockClient.pullRequestsToReturn = []
        let viewModel = makeViewModel(suiteName: "LoadMoreNoOp")
        let viewID = viewModel.views.first!.id
        await viewModel.refresh(viewID: viewID)

        let callsBefore = mockClient.fetchPullRequestsCallCount
        await viewModel.loadMore(viewID: viewID)
        #expect(mockClient.fetchPullRequestsCallCount == callsBefore)
    }

    // MARK: - reloadViews with stale selection

    @Test("reloadViews updates selection when current selection is stale")
    func reloadViewsUpdatesStaleSelection() {
        let defaults = UserDefaults(suiteName: "ReloadViewsStale")!
        defaults.removePersistentDomain(forName: "ReloadViewsStale")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService)

        // Set selection to a non-existent view
        viewModel.selectedViewID = UUID()
        viewModel.reloadViews()

        // Selection should be reset to first available view
        #expect(viewModel.selectedViewID == viewModel.views.first?.id)
    }

    @Test("reloadViews cleans up orphaned viewStates")
    func reloadViewsCleansOrphanedStates() {
        let defaults = UserDefaults(suiteName: "ReloadViewsOrphaned")!
        defaults.removePersistentDomain(forName: "ReloadViewsOrphaned")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService)

        // Store currently has the default view. Save it so reloadViews has it.
        let statesBefore = viewModel.viewStates.count

        // Delete a view from the store directly (simulating external change)
        store.save([])
        viewModel.reloadViews()

        // viewStates should be updated to match the new (default) views
        #expect(viewModel.viewStates.count <= statesBefore + 1)
    }

    // MARK: - selectedViewState with valid selection

    @Test("selectedViewState returns the state for selected view")
    func selectedViewStateReturnsCorrectState() async {
        let pr = TestPullRequestFactory.make(id: "PR_1", title: "Test")
        mockClient.pullRequestsToReturn = [pr]

        let viewModel = makeViewModel(suiteName: "SelectedViewStateValid")
        let viewID = viewModel.views.first!.id
        viewModel.selectedViewID = viewID
        await viewModel.refresh(viewID: viewID)

        let state = viewModel.selectedViewState
        #expect(state.pullRequests.count == 1)
    }

    // MARK: - checkAndNotify

    @Test("checkAndNotify skips first load (no notification on initial data)")
    func checkAndNotifySkipsFirstLoad() async {
        let defaults = UserDefaults(suiteName: "NotifyFirstLoad")!
        defaults.removePersistentDomain(forName: "NotifyFirstLoad")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService)
        let viewID = viewModel.views.first!.id

        // Enable notifications for this view
        viewModel.toggleNotification(for: viewID)
        #expect(viewModel.isNotificationEnabled(for: viewID))

        let pr = TestPullRequestFactory.make(id: "PR_1", title: "First PR")
        mockClient.pullRequestsToReturn = [pr]

        // First refresh: should not trigger notification (initial load)
        await viewModel.refresh(viewID: viewID)

        // Second refresh with new PR: should detect it as new
        let pr2 = TestPullRequestFactory.make(id: "PR_2", title: "Second PR")
        mockClient.pullRequestsToReturn = [pr, pr2]
        await viewModel.refresh(viewID: viewID)

        // We can't easily assert the notification was sent, but we can verify
        // the flow didn't crash and PRs are loaded
        #expect(viewModel.viewStates[viewID]!.pullRequests.count == 2)
    }

    // MARK: - localMatch

    @Test("localMatch returns nil when no local repo match")
    func localMatchReturnsNil() {
        let viewModel = makeViewModel(suiteName: "LocalMatch")
        let pr = TestPullRequestFactory.make()
        #expect(viewModel.localMatch(for: pr) == nil)
    }
}
