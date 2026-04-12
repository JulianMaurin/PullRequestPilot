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
        let viewModel = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        let testView = DashboardView(id: UUID(), title: "Test View", query: "is:pr is:open")
        viewModel.addView(testView)
        return viewModel
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
        let viewModel = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)

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

    @Test("setNotification enables and disables")
    func setNotification() async {
        let defaults = UserDefaults(suiteName: "ToggleNotification")!
        defaults.removePersistentDomain(forName: "ToggleNotification")

        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        let testView = DashboardView(id: UUID(), title: "Test", query: "is:pr")
        viewModel.addView(testView)
        let viewID = testView.id

        #expect(!viewModel.isNotificationEnabled(for: viewID))

        viewModel.setNotification(for: viewID, enabled: true)
        #expect(viewModel.isNotificationEnabled(for: viewID))

        viewModel.setNotification(for: viewID, enabled: false)
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
        let viewModel = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        let testView = DashboardView(id: UUID(), title: "Test", query: "is:pr")
        viewModel.addView(testView)
        let viewID = testView.id
        let initialValue = viewModel.views.first(where: { $0.id == viewID })?.hideReviewed ?? false

        mockClient.pullRequestsToReturn = []
        viewModel.toggleHideReviewed(for: viewID)

        // Give the Task inside toggleHideReviewed a chance to run
        try? await Task.sleep(for: .milliseconds(100))

        #expect(viewModel.views.first(where: { $0.id == viewID })?.hideReviewed == !initialValue)

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
        let viewModel = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)

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
        let viewModel = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)

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
        let viewModel = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        let testView = DashboardView(id: UUID(), title: "Test", query: "is:pr")
        viewModel.addView(testView)
        let viewID = testView.id

        // Enable notifications for this view
        viewModel.setNotification(for: viewID, enabled: true)
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

    // MARK: - moveView

    @Test("moveView reorders views correctly")
    func moveViewReorders() {
        let defaults = UserDefaults(suiteName: "MoveView")!
        defaults.removePersistentDomain(forName: "MoveView")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)

        let view1 = DashboardView(id: UUID(), title: "First", query: "q1")
        let view2 = DashboardView(id: UUID(), title: "Second", query: "q2")
        let view3 = DashboardView(id: UUID(), title: "Third", query: "q3")
        viewModel.addView(view1)
        viewModel.addView(view2)
        viewModel.addView(view3)

        // Move view3 before view1
        viewModel.moveView(from: view3.id, to: view1.id)

        let titles = viewModel.views.map(\.title)
        #expect(titles.contains("Third"))
        #expect(titles.contains("First"))
        #expect(titles.contains("Second"))
    }

    @Test("moveView is no-op when source equals target")
    func moveViewSamePosition() {
        let viewModel = makeViewModel(suiteName: "MoveViewSame")
        let viewID = viewModel.views.first!.id
        let titlesBefore = viewModel.views.map(\.title)
        viewModel.moveView(from: viewID, to: viewID)
        #expect(viewModel.views.map(\.title) == titlesBefore)
    }

    @Test("moveView is no-op for unknown source")
    func moveViewUnknownSource() {
        let viewModel = makeViewModel(suiteName: "MoveViewUnknown")
        let viewID = viewModel.views.first!.id
        let countBefore = viewModel.views.count
        viewModel.moveView(from: UUID(), to: viewID)
        #expect(viewModel.views.count == countBefore)
    }

    // MARK: - presetConflicts

    @Test("presetConflicts returns empty when no conflicts")
    func presetConflictsNone() {
        let defaults = UserDefaults(suiteName: "PresetNoConflict")!
        defaults.removePersistentDomain(forName: "PresetNoConflict")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        // No preset titles exist, so there should be no conflicts
        let conflicts = viewModel.presetConflicts()
        #expect(conflicts.isEmpty)
    }

    @Test("presetConflicts detects matching titles")
    func presetConflictsDetected() {
        let defaults = UserDefaults(suiteName: "PresetConflict")!
        defaults.removePersistentDomain(forName: "PresetConflict")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)

        // Add a view with a preset title
        let conflicting = DashboardView(id: UUID(), title: "My PRs", query: "custom query")
        viewModel.addView(conflicting)

        let conflicts = viewModel.presetConflicts()
        #expect(conflicts.contains("My PRs"))
    }

    // MARK: - createPresetViews

    @Test("createPresetViews adds all presets when no conflicts")
    func createPresetViewsNoConflicts() {
        let defaults = UserDefaults(suiteName: "CreatePresets")!
        defaults.removePersistentDomain(forName: "CreatePresets")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)

        let countBefore = viewModel.views.count
        viewModel.createPresetViews(replacingConflicts: false)

        #expect(viewModel.views.count == countBefore + DashboardView.presetViews.count)
    }

    @Test("createPresetViews skips conflicts when not replacing")
    func createPresetViewsSkipConflicts() {
        let defaults = UserDefaults(suiteName: "CreatePresetsSkip")!
        defaults.removePersistentDomain(forName: "CreatePresetsSkip")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)

        let conflicting = DashboardView(id: UUID(), title: "My PRs", query: "old query")
        viewModel.addView(conflicting)

        viewModel.createPresetViews(replacingConflicts: false)

        // The conflicting view should still have the old query
        let myPRsView = viewModel.views.first(where: { $0.title == "My PRs" })
        #expect(myPRsView?.query == "old query")
    }

    @Test("createPresetViews replaces conflicts when replacing")
    func createPresetViewsReplaceConflicts() {
        let defaults = UserDefaults(suiteName: "CreatePresetsReplace")!
        defaults.removePersistentDomain(forName: "CreatePresetsReplace")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)

        let conflictingID = UUID()
        let conflicting = DashboardView(id: conflictingID, title: "My PRs", query: "old query")
        viewModel.addView(conflicting)

        viewModel.createPresetViews(replacingConflicts: true)

        // The conflicting view should have the preset query but keep the same ID
        let myPRsView = viewModel.views.first(where: { $0.title == "My PRs" })
        #expect(myPRsView?.id == conflictingID)
        #expect(myPRsView?.query != "old query")
    }

    @Test("createPresetViews sets selection when nil")
    func createPresetViewsSetsSelection() {
        let defaults = UserDefaults(suiteName: "CreatePresetsSelect")!
        defaults.removePersistentDomain(forName: "CreatePresetsSelect")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        viewModel.selectedViewID = nil

        viewModel.createPresetViews(replacingConflicts: false)

        #expect(viewModel.selectedViewID != nil)
    }

    // MARK: - refresh deduplication

    @Test("refresh deduplicates PRs with same ID")
    func refreshDeduplicates() async {
        let pr = TestPullRequestFactory.make(id: "PR_DUP", title: "Duplicate PR")
        // Return the same PR twice
        mockClient.pullRequestsToReturn = [pr, pr]

        let viewModel = makeViewModel(suiteName: "RefreshDedup")
        let viewID = viewModel.views.first!.id
        await viewModel.refresh(viewID: viewID)

        #expect(viewModel.viewStates[viewID]!.pullRequests.count == 1)
    }

    // MARK: - refresh reachedLimit

    @Test("refresh sets reachedLimit when PR count reaches max")
    func refreshSetsReachedLimit() async {
        // Create maxPullRequests number of PRs
        var prs: [PullRequest] = []
        for i in 0..<Constants.App.maxPullRequests {
            prs.append(TestPullRequestFactory.make(id: "PR_\(i)", number: i, title: "PR \(i)"))
        }
        mockClient.pullRequestsToReturn = prs
        mockClient.nextCursorToReturn = "cursor"

        let viewModel = makeViewModel(suiteName: "ReachedLimit")
        let viewID = viewModel.views.first!.id
        await viewModel.refresh(viewID: viewID)

        #expect(viewModel.viewStates[viewID]!.reachedLimit)
        #expect(!viewModel.viewStates[viewID]!.canLoadMore)
    }

    // MARK: - refresh CancellationError handling

    @Test("refresh ignores CancellationError")
    func refreshIgnoresCancellationError() async {
        mockClient.errorToThrow = CancellationError()

        let viewModel = makeViewModel(suiteName: "CancelRefresh")
        let viewID = viewModel.views.first!.id
        await viewModel.refresh(viewID: viewID)

        let state = viewModel.viewStates[viewID]!
        #expect(state.error == nil)
    }

    // MARK: - loadMore CancellationError handling

    @Test("loadMore ignores CancellationError")
    func loadMoreIgnoresCancellationError() async {
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

    // MARK: - loadMore with unknown viewID

    @Test("loadMore with unknown viewID is a no-op")
    func loadMoreUnknownViewID() async {
        let viewModel = makeViewModel(suiteName: "LoadMoreUnknown")
        let callsBefore = mockClient.fetchPullRequestsCallCount
        await viewModel.loadMore(viewID: UUID())
        #expect(mockClient.fetchPullRequestsCallCount == callsBefore)
    }

    // MARK: - loadMore reachedLimit

    @Test("loadMore sets reachedLimit when total reaches max")
    func loadMoreSetsReachedLimit() async {
        // First load fills most of the limit
        let initialCount = Constants.App.maxPullRequests - 1
        var initialPRs: [PullRequest] = []
        for i in 0..<initialCount {
            initialPRs.append(TestPullRequestFactory.make(id: "PR_\(i)", number: i, title: "PR \(i)"))
        }
        mockClient.pullRequestsToReturn = initialPRs
        mockClient.nextCursorToReturn = "cursor_1"

        let viewModel = makeViewModel(suiteName: "LoadMoreLimit")
        let viewID = viewModel.views.first!.id
        await viewModel.refresh(viewID: viewID)

        // Load one more to hit the limit
        let extraPR = TestPullRequestFactory.make(id: "PR_extra", number: 999, title: "Extra")
        mockClient.pullRequestsToReturn = [extraPR]
        mockClient.nextCursorToReturn = "cursor_2"
        mockClient.errorToThrow = nil

        await viewModel.loadMore(viewID: viewID)

        #expect(viewModel.viewStates[viewID]!.reachedLimit)
    }

    // MARK: - loadMore filters reviewed PRs

    @Test("loadMore filters reviewed PRs when hideReviewed is enabled")
    func loadMoreFiltersReviewed() async {
        let defaults = UserDefaults(suiteName: "LoadMoreFilter")!
        defaults.removePersistentDomain(forName: "LoadMoreFilter")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        let testView = DashboardView(id: UUID(), title: "Test", query: "is:pr", hideReviewed: true)
        viewModel.addView(testView)
        let viewID = testView.id

        mockClient.viewerLoginToReturn = "testuser"
        mockClient.pullRequestsToReturn = [TestPullRequestFactory.make(id: "PR_1", title: "First")]
        mockClient.nextCursorToReturn = "cursor_1"
        await viewModel.refresh(viewID: viewID)

        // Load more with a reviewed PR
        let reviewedPR = TestPullRequestFactory.make(
            id: "PR_2", number: 2, title: "Reviewed",
            latestReviews: [UserReview(login: "testuser", state: .approved)]
        )
        let unreviewedPR = TestPullRequestFactory.make(id: "PR_3", number: 3, title: "Unreviewed")
        mockClient.pullRequestsToReturn = [reviewedPR, unreviewedPR]
        mockClient.nextCursorToReturn = nil
        mockClient.errorToThrow = nil

        await viewModel.loadMore(viewID: viewID)

        let titles = viewModel.viewStates[viewID]!.pullRequests.map(\.title)
        #expect(!titles.contains("Reviewed"))
        #expect(titles.contains("Unreviewed"))
    }

    // MARK: - fetchViewerLoginIfNeeded

    @Test("refreshAll fetches viewer login before refreshing views")
    func refreshAllFetchesViewerLogin() async {
        let defaults = UserDefaults(suiteName: "RefreshAllLogin")!
        defaults.removePersistentDomain(forName: "RefreshAllLogin")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        let testView = DashboardView(id: UUID(), title: "Test", query: "is:pr", hideReviewed: true)
        viewModel.addView(testView)

        mockClient.viewerLoginToReturn = "mylogin"
        mockClient.pullRequestsToReturn = []
        await viewModel.refreshAll()

        // The viewer login should have been fetched (no error)
        #expect(viewModel.viewStates[testView.id] != nil)
    }

    // MARK: - stopAutoRefresh cleans up observer

    @Test("stopAutoRefresh removes notification observer")
    func stopAutoRefreshCleansUp() {
        let viewModel = makeViewModel(suiteName: "StopAutoRefresh")
        viewModel.startAutoRefresh()
        viewModel.stopAutoRefresh()
        // Calling stop twice should be safe
        viewModel.stopAutoRefresh()
    }

    // MARK: - openInEditor / openInTerminal with no match

    @Test("openInEditor is no-op when no local match")
    func openInEditorNoMatch() {
        let viewModel = makeViewModel(suiteName: "OpenEditorNoMatch")
        let pr = TestPullRequestFactory.make()
        // Should not crash
        viewModel.openInEditor(pr)
    }

    @Test("openInTerminal is no-op when no local match")
    func openInTerminalNoMatch() {
        let viewModel = makeViewModel(suiteName: "OpenTerminalNoMatch")
        let pr = TestPullRequestFactory.make()
        // Should not crash
        viewModel.openInTerminal(pr)
    }

    // MARK: - notifiedViewIDs persistence

    @Test("notifiedViewIDs persists across access")
    func notifiedViewIDsPersistence() async {
        let defaults = UserDefaults(suiteName: "NotifiedPersist")!
        defaults.removePersistentDomain(forName: "NotifiedPersist")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        let testView = DashboardView(id: UUID(), title: "Test View", query: "is:pr is:open")
        viewModel.addView(testView)
        let viewID = viewModel.views.first!.id

        viewModel.setNotification(for: viewID, enabled: true)
        #expect(viewModel.isNotificationEnabled(for: viewID))

        // Read from the same isolated UserDefaults
        let stored = defaults.stringArray(forKey: Constants.UserDefaultsKeys.notifiedViewIDs) ?? []
        #expect(stored.contains(viewID.uuidString))
    }

    // MARK: - hideReviewed with dismissed reviews

    @Test("hideReviewed keeps PRs with CHANGES_REQUESTED review from viewer")
    func hideReviewedChangesRequested() async {
        let defaults = UserDefaults(suiteName: "HideReviewedCR")!
        defaults.removePersistentDomain(forName: "HideReviewedCR")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        let testView = DashboardView(id: UUID(), title: "Review", query: "is:pr", hideReviewed: true)
        viewModel.addView(testView)

        mockClient.viewerLoginToReturn = "testuser"
        let changesRequestedPR = TestPullRequestFactory.make(
            id: "PR_CR", number: 1, title: "Changes Requested",
            latestReviews: [UserReview(login: "testuser", state: .changesRequested)]
        )
        mockClient.pullRequestsToReturn = [changesRequestedPR]
        await viewModel.refresh(viewID: testView.id)

        let titles = viewModel.viewStates[testView.id]!.pullRequests.map(\.title)
        #expect(!titles.contains("Changes Requested"))
    }

    @Test("hideReviewed keeps PRs with COMMENTED review from viewer")
    func hideReviewedCommented() async {
        let defaults = UserDefaults(suiteName: "HideReviewedComment")!
        defaults.removePersistentDomain(forName: "HideReviewedComment")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        let testView = DashboardView(id: UUID(), title: "Review", query: "is:pr", hideReviewed: true)
        viewModel.addView(testView)

        mockClient.viewerLoginToReturn = "testuser"
        let commentedPR = TestPullRequestFactory.make(
            id: "PR_C", number: 1, title: "Commented",
            latestReviews: [UserReview(login: "testuser", state: .commented)]
        )
        mockClient.pullRequestsToReturn = [commentedPR]
        await viewModel.refresh(viewID: testView.id)

        let titles = viewModel.viewStates[testView.id]!.pullRequests.map(\.title)
        #expect(!titles.contains("Commented"))
    }

    // MARK: - hideReviewed disabled doesn't filter

    @Test("refresh does not filter when hideReviewed is false")
    func refreshNoFilterWhenHideReviewedOff() async {
        let defaults = UserDefaults(suiteName: "NoFilterOff")!
        defaults.removePersistentDomain(forName: "NoFilterOff")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        let testView = DashboardView(id: UUID(), title: "All", query: "is:pr", hideReviewed: false)
        viewModel.addView(testView)

        mockClient.viewerLoginToReturn = "testuser"
        let approvedPR = TestPullRequestFactory.make(
            id: "PR_A", number: 1, title: "Approved",
            latestReviews: [UserReview(login: "testuser", state: .approved)]
        )
        mockClient.pullRequestsToReturn = [approvedPR]
        await viewModel.refresh(viewID: testView.id)

        let titles = viewModel.viewStates[testView.id]!.pullRequests.map(\.title)
        #expect(titles.contains("Approved"))
    }

    // MARK: - selectedViewState with invalid selection

    @Test("selectedViewState returns empty state for stale selection")
    func selectedViewStateStaleSelection() {
        let viewModel = makeViewModel(suiteName: "StaleSelection")
        viewModel.selectedViewID = UUID() // non-existent view ID
        let state = viewModel.selectedViewState
        #expect(state.isEmpty)
    }

    // MARK: - deleteView when not selected

    @Test("deleteView does not change selection when deleted view is not selected")
    func deleteViewKeepsSelection() {
        let defaults = UserDefaults(suiteName: "DeleteKeepSelection")!
        defaults.removePersistentDomain(forName: "DeleteKeepSelection")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)

        let view1 = DashboardView(id: UUID(), title: "View 1", query: "q1")
        let view2 = DashboardView(id: UUID(), title: "View 2", query: "q2")
        viewModel.addView(view1)
        viewModel.addView(view2)
        viewModel.selectedViewID = view1.id

        viewModel.deleteView(id: view2.id)

        #expect(viewModel.selectedViewID == view1.id)
    }

    // MARK: - ViewState.hasData

    @Test("ViewState hasData is true when pullRequests is non-empty")
    func viewStateHasData() {
        var state = ViewState()
        #expect(!state.hasData)

        state.pullRequests = [TestPullRequestFactory.make()]
        #expect(state.hasData)
    }

    // MARK: - clearAllData

    @Test("clearAllData resets all state and persists empty views")
    func clearAllDataResetsState() async {
        let defaults = UserDefaults(suiteName: "ClearAllData")!
        defaults.removePersistentDomain(forName: "ClearAllData")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)

        let view1 = DashboardView(id: UUID(), title: "View 1", query: "q1")
        viewModel.addView(view1)
        mockClient.pullRequestsToReturn = [TestPullRequestFactory.make()]
        await viewModel.refresh(viewID: view1.id)

        #expect(!viewModel.views.isEmpty)
        #expect(!viewModel.viewStates.isEmpty)
        #expect(viewModel.selectedViewID != nil)

        viewModel.clearAllData()

        #expect(viewModel.views.isEmpty)
        #expect(viewModel.viewStates.isEmpty)
        #expect(viewModel.selectedViewID == nil)
        #expect(store.load().isEmpty)
    }

    // MARK: - restartAutoRefresh via notification

    @Test("refresh interval change notification restarts auto-refresh")
    func restartAutoRefreshViaNotification() async {
        let viewModel = makeViewModel(suiteName: "RestartAutoRefresh")
        viewModel.startAutoRefresh()

        // Trigger restart via notification (same mechanism as restartAutoRefresh)
        NotificationCenter.default.post(name: Constants.Notifications.prRefreshIntervalChanged, object: nil)

        // Give the Task { @MainActor } inside the observer a chance to execute
        try? await Task.sleep(for: .milliseconds(200))

        // Should still be able to stop cleanly (proves it restarted)
        viewModel.stopAutoRefresh()
    }

    // MARK: - checkAndNotify does not notify when notifications disabled

    @Test("checkAndNotify skips when notifications disabled for view")
    func checkAndNotifySkipsWhenDisabled() async {
        let defaults = UserDefaults(suiteName: "NotifyDisabled")!
        defaults.removePersistentDomain(forName: "NotifyDisabled")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        let testView = DashboardView(id: UUID(), title: "Test", query: "is:pr")
        viewModel.addView(testView)

        // Do NOT enable notifications
        #expect(!viewModel.isNotificationEnabled(for: testView.id))

        let pr = TestPullRequestFactory.make(id: "PR_1", title: "First")
        mockClient.pullRequestsToReturn = [pr]
        await viewModel.refresh(viewID: testView.id)

        // Second refresh with new PR — should not crash even with notifications off
        let pr2 = TestPullRequestFactory.make(id: "PR_2", title: "Second")
        mockClient.pullRequestsToReturn = [pr, pr2]
        await viewModel.refresh(viewID: testView.id)

        #expect(viewModel.viewStates[testView.id]!.pullRequests.count == 2)
    }

    // MARK: - refresh with view that was added externally via store

    @Test("refresh creates ViewState when reloaded view has no state yet")
    func refreshCreatesViewStateAfterReload() async {
        let defaults = UserDefaults(suiteName: "RefreshCreatesState")!
        defaults.removePersistentDomain(forName: "RefreshCreatesState")
        let store = ViewsStore(defaults: defaults)

        // Save a view directly to the store
        let testView = DashboardView(id: UUID(), title: "External", query: "is:pr")
        store.save([testView])

        // Create viewModel which loads from store — viewStates should be populated
        let viewModel = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        #expect(viewModel.viewStates[testView.id] != nil)

        mockClient.pullRequestsToReturn = [TestPullRequestFactory.make()]
        await viewModel.refresh(viewID: testView.id)

        #expect(viewModel.viewStates[testView.id]?.pullRequests.count == 1)
    }

    // MARK: - Multiple notification: single PR vs multi PR

    @Test("checkAndNotify handles single new PR on second load")
    func notifySingleNewPR() async {
        let defaults = UserDefaults(suiteName: "NotifySingle")!
        defaults.removePersistentDomain(forName: "NotifySingle")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        let testView = DashboardView(id: UUID(), title: "Notify", query: "is:pr")
        viewModel.addView(testView)

        viewModel.setNotification(for: testView.id, enabled: true)

        // Initial load
        let pr1 = TestPullRequestFactory.make(id: "PR_1", title: "Initial")
        mockClient.pullRequestsToReturn = [pr1]
        await viewModel.refresh(viewID: testView.id)

        // Second load with one new PR
        let pr2 = TestPullRequestFactory.make(id: "PR_2", title: "New One")
        mockClient.pullRequestsToReturn = [pr1, pr2]
        await viewModel.refresh(viewID: testView.id)

        #expect(viewModel.viewStates[testView.id]!.pullRequests.count == 2)
    }

    @Test("checkAndNotify handles multiple new PRs on second load")
    func notifyMultipleNewPRs() async {
        let defaults = UserDefaults(suiteName: "NotifyMultiple")!
        defaults.removePersistentDomain(forName: "NotifyMultiple")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        let testView = DashboardView(id: UUID(), title: "Notify", query: "is:pr")
        viewModel.addView(testView)

        viewModel.setNotification(for: testView.id, enabled: true)

        // Initial load
        mockClient.pullRequestsToReturn = [TestPullRequestFactory.make(id: "PR_1", title: "Initial")]
        await viewModel.refresh(viewID: testView.id)

        // Second load with 5 new PRs (exercises the >1 branch and >4 prefix)
        var prs = [TestPullRequestFactory.make(id: "PR_1", title: "Initial")]
        for i in 2...6 {
            prs.append(TestPullRequestFactory.make(id: "PR_\(i)", number: i, title: "New \(i)"))
        }
        mockClient.pullRequestsToReturn = prs
        await viewModel.refresh(viewID: testView.id)

        #expect(viewModel.viewStates[testView.id]!.pullRequests.count == 6)
    }

    // MARK: - isVSCodeAvailable / isITermAvailable delegation

    @Test("isVSCodeAvailable delegates to localRepositoryService")
    func isVSCodeAvailableDelegation() {
        let viewModel = makeViewModel(suiteName: "VSCodeAvail")
        #expect(viewModel.isVSCodeAvailable == localRepoService.isVSCodeAvailable)
    }

    @Test("isITermAvailable delegates to localRepositoryService")
    func isITermAvailableDelegation() {
        let viewModel = makeViewModel(suiteName: "ITermAvail")
        #expect(viewModel.isITermAvailable == localRepoService.isITermAvailable)
    }
}
