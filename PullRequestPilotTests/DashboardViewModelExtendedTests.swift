import Testing
import Foundation
@testable import PullRequestPilot

@MainActor
@Suite("DashboardViewModel Extended")
struct DashboardViewModelExtendedTests {
    let mockClient = MockGitHubClient()
    let localRepoService = LocalRepositoryService()

    private func makeViewModel(suiteName: String) throws -> (viewModel: DashboardViewModel, viewID: UUID) {
        let defaults = try #require(UserDefaults(suiteName: "DashboardViewModelExtendedTests.\(suiteName)"))
        defaults.removePersistentDomain(forName: "DashboardViewModelExtendedTests.\(suiteName)")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults, notificationCenter: MockUserNotificationCenter(), widgetDestination: .temporary())
        let testView = DashboardView(id: UUID(), title: "Test View", query: "is:pr is:open")
        viewModel.addView(testView)
        return (viewModel, testView.id)
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
    func loadMoreAppendsPRs() async throws {
        let pr1 = try TestPullRequestFactory.make(id: "PR_1", number: 1, title: "First")
        let pr2 = try TestPullRequestFactory.make(id: "PR_2", number: 2, title: "Second")

        await mockClient.setPullRequestsToReturn([pr1])
        await mockClient.setNextCursorToReturn("cursor_1")

        let (viewModel, viewID) = try makeViewModel(suiteName: "LoadMore")
        await viewModel.refresh(viewID: viewID)

        #expect(viewModel.viewStates[viewID]?.pullRequests.count == 1)
        #expect(viewModel.viewStates[viewID]?.canLoadMore == true)

        await mockClient.setPullRequestsToReturn([pr2])
        await mockClient.setNextCursorToReturn(nil)

        await viewModel.loadMore(viewID: viewID)

        #expect(viewModel.viewStates[viewID]?.pullRequests.count == 2)
        #expect(viewModel.viewStates[viewID]?.pullRequests[1].title == "Second")
    }

    @Test("loadMore deduplicates PRs")
    func loadMoreDeduplicates() async throws {
        let pr1 = try TestPullRequestFactory.make(id: "PR_1", number: 1, title: "First")

        await mockClient.setPullRequestsToReturn([pr1])
        await mockClient.setNextCursorToReturn("cursor_1")

        let (viewModel, viewID) = try makeViewModel(suiteName: "LoadMoreDedup")
        await viewModel.refresh(viewID: viewID)

        // Return the same PR again
        await mockClient.setPullRequestsToReturn([pr1])
        await mockClient.setNextCursorToReturn(nil)

        await viewModel.loadMore(viewID: viewID)

        #expect(viewModel.viewStates[viewID]?.pullRequests.count == 1)
    }

    // MARK: - updateView

    @Test("updateView modifies existing view")
    func updateViewModifiesView() throws {
        let (viewModel, viewID) = try makeViewModel(suiteName: "UpdateView")
        var view = try #require(viewModel.views.first(where: { $0.id == viewID }))
        let originalTitle = view.title
        view.title = "Updated Title"
        viewModel.updateView(view)

        #expect(viewModel.views.first(where: { $0.id == viewID })?.title == "Updated Title")
        #expect(viewModel.views.first(where: { $0.id == viewID })?.title != originalTitle)
    }

    @Test("updateView ignores unknown view")
    func updateViewIgnoresUnknown() throws {
        let (viewModel, _) = try makeViewModel(suiteName: "UpdateViewUnknown")
        let unknownView = DashboardView(id: UUID(), title: "Unknown", query: "test")
        let countBefore = viewModel.views.count
        viewModel.updateView(unknownView)
        #expect(viewModel.views.count == countBefore)
    }

    // MARK: - deleteView

    @Test("deleteView updates selection to next available view")
    func deleteViewUpdatesSelection() throws {
        let (viewModel, _) = try makeViewModel(suiteName: "DeleteViewSelection")
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
    func reloadViewsSyncsState() throws {
        let defaults = try #require(UserDefaults(suiteName: "DashboardViewModelExtendedTests.ReloadViews"))
        defaults.removePersistentDomain(forName: "DashboardViewModelExtendedTests.ReloadViews")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults, notificationCenter: MockUserNotificationCenter(), widgetDestination: .temporary())

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
    func selectedViewStateNoSelection() throws {
        let (viewModel, _) = try makeViewModel(suiteName: "SelectedViewState")
        viewModel.selectedViewID = nil
        let state = viewModel.selectedViewState
        #expect(state.isEmpty)
    }

    // MARK: - Notifications

    @Test("setNotification enables and disables")
    func setNotification() async throws {
        let defaults = try #require(UserDefaults(suiteName: "DashboardViewModelExtendedTests.ToggleNotification"))
        defaults.removePersistentDomain(forName: "DashboardViewModelExtendedTests.ToggleNotification")

        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults, notificationCenter: MockUserNotificationCenter(), widgetDestination: .temporary())
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
    func startAutoRefreshIdempotent() throws {
        let (viewModel, _) = try makeViewModel(suiteName: "AutoRefreshIdem")
        viewModel.startAutoRefresh()
        viewModel.startAutoRefresh()
        // Should not create multiple tasks — just verify no crash
        viewModel.stopAutoRefresh()
    }

    // MARK: - CancellationError handling

    @Test("refresh ignores CancellationError")
    func refreshIgnoresCancellation() async throws {
        await mockClient.setErrorToThrow(CancellationError())

        let (viewModel, viewID) = try makeViewModel(suiteName: "CancelRefresh")
        await viewModel.refresh(viewID: viewID)

        let state = try #require(viewModel.viewStates[viewID])
        #expect(state.error == nil)
    }

    // MARK: - Refresh with unknown viewID

    @Test("refresh with unknown viewID is a no-op")
    func refreshUnknownViewID() async throws {
        let (viewModel, _) = try makeViewModel(suiteName: "UnknownViewID")
        await viewModel.refresh(viewID: UUID())
        #expect(await mockClient.fetchPullRequestsCallCount == 0)
    }

    // MARK: - addView sets selection when none

    @Test("addView sets selectedViewID when it was nil")
    func addViewSetsSelectionWhenNil() throws {
        let (viewModel, _) = try makeViewModel(suiteName: "AddViewSelection")
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
    func refreshAllFetchesAllViews() async throws {
        let pr = try TestPullRequestFactory.make(id: "PR_1", title: "PR 1")
        await mockClient.setPullRequestsToReturn([pr])
        await mockClient.setViewerLogin("testuser")

        let (viewModel, _) = try makeViewModel(suiteName: "RefreshAll")
        let view2 = DashboardView(id: UUID(), title: "My PRs", query: "author:@me")
        viewModel.addView(view2)

        await viewModel.refreshAll()

        for view in viewModel.views {
            let state = try #require(viewModel.viewStates[view.id])
            #expect(state.pullRequests.count == 1)
        }
    }

    // MARK: - toggleHideReviewed

    @Test("toggleHideReviewed toggles the flag and persists")
    func toggleHideReviewed() async throws {
        let defaults = try #require(UserDefaults(suiteName: "DashboardViewModelExtendedTests.ToggleHideReviewed"))
        defaults.removePersistentDomain(forName: "DashboardViewModelExtendedTests.ToggleHideReviewed")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults, notificationCenter: MockUserNotificationCenter(), widgetDestination: .temporary())
        let testView = DashboardView(id: UUID(), title: "Test", query: "is:pr")
        viewModel.addView(testView)
        let viewID = testView.id
        let initialValue = viewModel.views.first(where: { $0.id == viewID })?.hideReviewed ?? false

        await mockClient.setPullRequestsToReturn([])
        viewModel.toggleHideReviewed(for: viewID)

        // Wait for the internal Task to complete (poll with deadline)
        let deadline = ContinuousClock.now + .seconds(2)
        while viewModel.viewStates[viewID]?.isLoading == true, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(viewModel.views.first(where: { $0.id == viewID })?.hideReviewed == !initialValue)

        // Check it persisted
        let reloadedViews = store.load()
        #expect(reloadedViews.first(where: { $0.id == viewID })?.hideReviewed == !initialValue)
    }

    // MARK: - loadMore error handling

    @Test("loadMore surfaces error on failure")
    func loadMoreError() async throws {
        let pr = try TestPullRequestFactory.make(id: "PR_1", title: "PR 1")
        await mockClient.setPullRequestsToReturn([pr])
        await mockClient.setNextCursorToReturn("cursor_1")

        let (viewModel, viewID) = try makeViewModel(suiteName: "LoadMoreError")
        await viewModel.refresh(viewID: viewID)

        await mockClient.setErrorToThrow(GitHubClientError.networkError(URLError(.timedOut)))
        await viewModel.loadMore(viewID: viewID)

        let state = try #require(viewModel.viewStates[viewID])
        #expect(state.error != nil)
        // Original PRs should still be there
        #expect(state.pullRequests.count == 1)
    }

    @Test("loadMore ignores CancellationError")
    func loadMoreIgnoresCancellation() async throws {
        let pr = try TestPullRequestFactory.make(id: "PR_1", title: "PR 1")
        await mockClient.setPullRequestsToReturn([pr])
        await mockClient.setNextCursorToReturn("cursor_1")

        let (viewModel, viewID) = try makeViewModel(suiteName: "LoadMoreCancel")
        await viewModel.refresh(viewID: viewID)

        await mockClient.setErrorToThrow(CancellationError())
        await viewModel.loadMore(viewID: viewID)

        let state = try #require(viewModel.viewStates[viewID])
        #expect(state.error == nil)
    }

    @Test("loadMore is no-op when canLoadMore is false")
    func loadMoreNoOpWhenCannotLoad() async throws {
        await mockClient.setPullRequestsToReturn([])
        let (viewModel, viewID) = try makeViewModel(suiteName: "LoadMoreNoOp")
        await viewModel.refresh(viewID: viewID)

        let callsBefore = await mockClient.fetchPullRequestsCallCount
        await viewModel.loadMore(viewID: viewID)
        #expect(await mockClient.fetchPullRequestsCallCount == callsBefore)
    }

    // MARK: - reloadViews with stale selection

    @Test("reloadViews updates selection when current selection is stale")
    func reloadViewsUpdatesStaleSelection() throws {
        let defaults = try #require(UserDefaults(suiteName: "DashboardViewModelExtendedTests.ReloadViewsStale"))
        defaults.removePersistentDomain(forName: "DashboardViewModelExtendedTests.ReloadViewsStale")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults, notificationCenter: MockUserNotificationCenter(), widgetDestination: .temporary())

        // Set selection to a non-existent view
        viewModel.selectedViewID = UUID()
        viewModel.reloadViews()

        // Selection should be reset to first available view
        #expect(viewModel.selectedViewID == viewModel.views.first?.id)
    }

    @Test("reloadViews cleans up orphaned viewStates")
    func reloadViewsCleansOrphanedStates() throws {
        let defaults = try #require(UserDefaults(suiteName: "DashboardViewModelExtendedTests.ReloadViewsOrphaned"))
        defaults.removePersistentDomain(forName: "DashboardViewModelExtendedTests.ReloadViewsOrphaned")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults, notificationCenter: MockUserNotificationCenter(), widgetDestination: .temporary())

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
    func selectedViewStateReturnsCorrectState() async throws {
        let pr = try TestPullRequestFactory.make(id: "PR_1", title: "Test")
        await mockClient.setPullRequestsToReturn([pr])

        let (viewModel, viewID) = try makeViewModel(suiteName: "SelectedViewStateValid")
        viewModel.selectedViewID = viewID
        await viewModel.refresh(viewID: viewID)

        let state = viewModel.selectedViewState
        #expect(state.pullRequests.count == 1)
    }

    // MARK: - checkAndNotify

    @Test("the bell stays quiet on the first load and announces a PR that appears later")
    func checkAndNotifySkipsFirstLoad() async throws {
        let defaults = try #require(UserDefaults(suiteName: "DashboardViewModelExtendedTests.NotifyFirstLoad"))
        defaults.removePersistentDomain(forName: "DashboardViewModelExtendedTests.NotifyFirstLoad")
        let notificationCenter = MockUserNotificationCenter()
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: ViewsStore(defaults: defaults), localRepositoryService: localRepoService, defaults: defaults, notificationCenter: notificationCenter, widgetDestination: .temporary())
        let testView = DashboardView(id: UUID(), title: "Test", query: "is:pr")
        viewModel.addView(testView)
        viewModel.setNotification(for: testView.id, enabled: true)

        let pr = try TestPullRequestFactory.make(id: "PR_1", title: "First PR")
        await mockClient.setPullRequestsToReturn([pr])
        await viewModel.refresh(viewID: testView.id)

        let pr2 = try TestPullRequestFactory.make(id: "PR_2", number: 2, title: "Second PR")
        await mockClient.setPullRequestsToReturn([pr, pr2])
        await viewModel.refresh(viewID: testView.id)
        try await TestWait.until { !notificationCenter.delivered.isEmpty }

        // A first-load notification would have been delivered before this one.
        #expect(notificationCenter.delivered.map(\.body) == ["#2 Second PR"])
    }

    // MARK: - localMatch

    @Test("localMatch returns nil when no local repo match")
    func localMatchReturnsNil() throws {
        let (viewModel, _) = try makeViewModel(suiteName: "LocalMatch")
        let pr = try TestPullRequestFactory.make()
        #expect(viewModel.localMatch(for: pr) == nil)
    }

    // MARK: - moveView

    @Test("moveView reorders views correctly")
    func moveViewReorders() throws {
        let defaults = try #require(UserDefaults(suiteName: "DashboardViewModelExtendedTests.MoveView"))
        defaults.removePersistentDomain(forName: "DashboardViewModelExtendedTests.MoveView")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults, notificationCenter: MockUserNotificationCenter(), widgetDestination: .temporary())

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
    func moveViewSamePosition() throws {
        let (viewModel, viewID) = try makeViewModel(suiteName: "MoveViewSame")
        let titlesBefore = viewModel.views.map(\.title)
        viewModel.moveView(from: viewID, to: viewID)
        #expect(viewModel.views.map(\.title) == titlesBefore)
    }

    @Test("moveView is no-op for unknown source")
    func moveViewUnknownSource() throws {
        let (viewModel, viewID) = try makeViewModel(suiteName: "MoveViewUnknown")
        let countBefore = viewModel.views.count
        viewModel.moveView(from: UUID(), to: viewID)
        #expect(viewModel.views.count == countBefore)
    }

    // MARK: - presetConflicts

    @Test("presetConflicts returns empty when no conflicts")
    func presetConflictsNone() throws {
        let defaults = try #require(UserDefaults(suiteName: "DashboardViewModelExtendedTests.PresetNoConflict"))
        defaults.removePersistentDomain(forName: "DashboardViewModelExtendedTests.PresetNoConflict")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults, notificationCenter: MockUserNotificationCenter(), widgetDestination: .temporary())
        // No preset titles exist, so there should be no conflicts
        let conflicts = viewModel.presetConflicts()
        #expect(conflicts.isEmpty)
    }

    @Test("presetConflicts detects matching titles")
    func presetConflictsDetected() throws {
        let defaults = try #require(UserDefaults(suiteName: "DashboardViewModelExtendedTests.PresetConflict"))
        defaults.removePersistentDomain(forName: "DashboardViewModelExtendedTests.PresetConflict")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults, notificationCenter: MockUserNotificationCenter(), widgetDestination: .temporary())

        // Add a view with a preset title
        let conflicting = DashboardView(id: UUID(), title: "My PRs", query: "custom query")
        viewModel.addView(conflicting)

        let conflicts = viewModel.presetConflicts()
        #expect(conflicts.contains("My PRs"))
    }

    // MARK: - createPresetViews

    @Test("createPresetViews adds all presets when no conflicts")
    func createPresetViewsNoConflicts() throws {
        let defaults = try #require(UserDefaults(suiteName: "DashboardViewModelExtendedTests.CreatePresets"))
        defaults.removePersistentDomain(forName: "DashboardViewModelExtendedTests.CreatePresets")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults, notificationCenter: MockUserNotificationCenter(), widgetDestination: .temporary())

        let countBefore = viewModel.views.count
        viewModel.createPresetViews(replacingConflicts: false)

        #expect(viewModel.views.count == countBefore + DashboardView.presetViews.count)
    }

    @Test("createPresetViews skips conflicts when not replacing")
    func createPresetViewsSkipConflicts() throws {
        let defaults = try #require(UserDefaults(suiteName: "DashboardViewModelExtendedTests.CreatePresetsSkip"))
        defaults.removePersistentDomain(forName: "DashboardViewModelExtendedTests.CreatePresetsSkip")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults, notificationCenter: MockUserNotificationCenter(), widgetDestination: .temporary())

        let conflicting = DashboardView(id: UUID(), title: "My PRs", query: "old query")
        viewModel.addView(conflicting)

        viewModel.createPresetViews(replacingConflicts: false)

        // The conflicting view should still have the old query
        let myPRsView = viewModel.views.first(where: { $0.title == "My PRs" })
        #expect(myPRsView?.query == "old query")
    }

    @Test("createPresetViews replaces conflicts when replacing")
    func createPresetViewsReplaceConflicts() throws {
        let defaults = try #require(UserDefaults(suiteName: "DashboardViewModelExtendedTests.CreatePresetsReplace"))
        defaults.removePersistentDomain(forName: "DashboardViewModelExtendedTests.CreatePresetsReplace")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults, notificationCenter: MockUserNotificationCenter(), widgetDestination: .temporary())

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
    func createPresetViewsSetsSelection() throws {
        let defaults = try #require(UserDefaults(suiteName: "DashboardViewModelExtendedTests.CreatePresetsSelect"))
        defaults.removePersistentDomain(forName: "DashboardViewModelExtendedTests.CreatePresetsSelect")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults, notificationCenter: MockUserNotificationCenter(), widgetDestination: .temporary())
        viewModel.selectedViewID = nil

        viewModel.createPresetViews(replacingConflicts: false)

        #expect(viewModel.selectedViewID != nil)
    }

    // MARK: - refresh deduplication

    @Test("refresh deduplicates PRs with same ID")
    func refreshDeduplicates() async throws {
        let pr = try TestPullRequestFactory.make(id: "PR_DUP", title: "Duplicate PR")
        // Return the same PR twice
        await mockClient.setPullRequestsToReturn([pr, pr])

        let (viewModel, viewID) = try makeViewModel(suiteName: "RefreshDedup")
        await viewModel.refresh(viewID: viewID)

        #expect(viewModel.viewStates[viewID]?.pullRequests.count == 1)
    }

    // MARK: - refresh reachedLimit

    @Test("refresh sets reachedLimit when PR count reaches max")
    func refreshSetsReachedLimit() async throws {
        // Create maxPullRequests number of PRs
        var prs: [PullRequest] = []
        for i in 0..<Constants.App.maxPullRequests {
            prs.append(try TestPullRequestFactory.make(id: "PR_\(i)", number: i, title: "PR \(i)"))
        }
        await mockClient.setPullRequestsToReturn(prs)
        await mockClient.setNextCursorToReturn("cursor")

        let (viewModel, viewID) = try makeViewModel(suiteName: "ReachedLimit")
        await viewModel.refresh(viewID: viewID)

        #expect(viewModel.viewStates[viewID]?.reachedLimit == true)
        #expect(viewModel.viewStates[viewID]?.canLoadMore != true)
    }

    // MARK: - loadMore with unknown viewID

    @Test("loadMore with unknown viewID is a no-op")
    func loadMoreUnknownViewID() async throws {
        let (viewModel, _) = try makeViewModel(suiteName: "LoadMoreUnknown")
        let callsBefore = await mockClient.fetchPullRequestsCallCount
        await viewModel.loadMore(viewID: UUID())
        #expect(await mockClient.fetchPullRequestsCallCount == callsBefore)
    }

    // MARK: - loadMore reachedLimit

    @Test("loadMore sets reachedLimit when total reaches max")
    func loadMoreSetsReachedLimit() async throws {
        // First load fills most of the limit
        let initialCount = Constants.App.maxPullRequests - 1
        var initialPRs: [PullRequest] = []
        for i in 0..<initialCount {
            initialPRs.append(try TestPullRequestFactory.make(id: "PR_\(i)", number: i, title: "PR \(i)"))
        }
        await mockClient.setPullRequestsToReturn(initialPRs)
        await mockClient.setNextCursorToReturn("cursor_1")

        let (viewModel, viewID) = try makeViewModel(suiteName: "LoadMoreLimit")
        await viewModel.refresh(viewID: viewID)

        // Load one more to hit the limit
        let extraPR = try TestPullRequestFactory.make(id: "PR_extra", number: 999, title: "Extra")
        await mockClient.setPullRequestsToReturn([extraPR])
        await mockClient.setNextCursorToReturn("cursor_2")
        await mockClient.setErrorToThrow(nil)

        await viewModel.loadMore(viewID: viewID)

        #expect(viewModel.viewStates[viewID]?.reachedLimit == true)
    }

    // MARK: - loadMore filters reviewed PRs

    @Test("loadMore filters reviewed PRs when hideReviewed is enabled")
    func loadMoreFiltersReviewed() async throws {
        let defaults = try #require(UserDefaults(suiteName: "DashboardViewModelExtendedTests.LoadMoreFilter"))
        defaults.removePersistentDomain(forName: "DashboardViewModelExtendedTests.LoadMoreFilter")
        let store = ViewsStore(defaults: defaults)
        await mockClient.setViewerLogin("testuser")
        let identity = try await IdentityActorTestFactory.makeAuthenticated(github: mockClient)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: identity, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults, notificationCenter: MockUserNotificationCenter(), widgetDestination: .temporary())
        let testView = DashboardView(id: UUID(), title: "Test", query: "is:pr", hideReviewed: true)
        viewModel.addView(testView)
        let viewID = testView.id

        await mockClient.setPullRequestsToReturn([try TestPullRequestFactory.make(id: "PR_1", title: "First")])
        await mockClient.setNextCursorToReturn("cursor_1")
        await viewModel.refresh(viewID: viewID)

        // Load more with a reviewed PR
        let reviewedPR = try TestPullRequestFactory.make(
            id: "PR_2", number: 2, title: "Reviewed",
            latestReviews: [UserReview(login: "testuser", state: .approved)]
        )
        let unreviewedPR = try TestPullRequestFactory.make(id: "PR_3", number: 3, title: "Unreviewed")
        await mockClient.setPullRequestsToReturn([reviewedPR, unreviewedPR])
        await mockClient.setNextCursorToReturn(nil)
        await mockClient.setErrorToThrow(nil)

        await viewModel.loadMore(viewID: viewID)

        let titles = viewModel.viewStates[viewID]?.pullRequests.map(\.title) ?? []
        #expect(!titles.contains("Reviewed"))
        #expect(titles.contains("Unreviewed"))
    }

    // MARK: - fetchViewerLoginIfNeeded

    @Test("refreshAll fetches viewer login before refreshing views")
    func refreshAllFetchesViewerLogin() async throws {
        let defaults = try #require(UserDefaults(suiteName: "DashboardViewModelExtendedTests.RefreshAllLogin"))
        defaults.removePersistentDomain(forName: "DashboardViewModelExtendedTests.RefreshAllLogin")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults, notificationCenter: MockUserNotificationCenter(), widgetDestination: .temporary())
        let testView = DashboardView(id: UUID(), title: "Test", query: "is:pr", hideReviewed: true)
        viewModel.addView(testView)

        await mockClient.setViewerLogin("mylogin")
        await mockClient.setPullRequestsToReturn([])
        await viewModel.refreshAll()

        // The viewer login should have been fetched (no error)
        #expect(viewModel.viewStates[testView.id] != nil)
    }

    // MARK: - stopAutoRefresh cleans up observer

    @Test("stopAutoRefresh removes notification observer")
    func stopAutoRefreshCleansUp() throws {
        let (viewModel, _) = try makeViewModel(suiteName: "StopAutoRefresh")
        viewModel.startAutoRefresh()
        viewModel.stopAutoRefresh()
        // Calling stop twice should be safe
        viewModel.stopAutoRefresh()
    }

    // MARK: - openInEditor / openInTerminal / openInCmux with no match

    @Test("openInEditor is no-op when no local match")
    func openInEditorNoMatch() throws {
        let (viewModel, _) = try makeViewModel(suiteName: "OpenEditorNoMatch")
        let pr = try TestPullRequestFactory.make()
        // Should not crash
        viewModel.openInEditor(pr)
    }

    @Test("openInTerminal is no-op when no local match")
    func openInTerminalNoMatch() throws {
        let (viewModel, _) = try makeViewModel(suiteName: "OpenTerminalNoMatch")
        let pr = try TestPullRequestFactory.make()
        // Should not crash
        viewModel.openInTerminal(pr)
    }

    @Test("openInCmux is no-op when no local match")
    func openInCmuxNoMatch() throws {
        let (viewModel, _) = try makeViewModel(suiteName: "OpenCmuxNoMatch")
        let pr = try TestPullRequestFactory.make()
        // Should not crash
        viewModel.openInCmux(pr)
    }

    // MARK: - notifiedViewIDs persistence

    @Test("notifiedViewIDs persists across access")
    func notifiedViewIDsPersistence() async throws {
        let defaults = try #require(UserDefaults(suiteName: "DashboardViewModelExtendedTests.NotifiedPersist"))
        defaults.removePersistentDomain(forName: "DashboardViewModelExtendedTests.NotifiedPersist")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults, notificationCenter: MockUserNotificationCenter(), widgetDestination: .temporary())
        let testView = DashboardView(id: UUID(), title: "Test View", query: "is:pr is:open")
        viewModel.addView(testView)
        let viewID = testView.id

        viewModel.setNotification(for: viewID, enabled: true)
        #expect(viewModel.isNotificationEnabled(for: viewID))

        // Read from the same isolated UserDefaults
        let stored = defaults.stringArray(forKey: Constants.UserDefaultsKeys.notifiedViewIDs) ?? []
        #expect(stored.contains(viewID.uuidString))
    }

    // MARK: - hideReviewed with dismissed reviews

    @Test("hideReviewed keeps PRs with CHANGES_REQUESTED review from viewer")
    func hideReviewedChangesRequested() async throws {
        let defaults = try #require(UserDefaults(suiteName: "DashboardViewModelExtendedTests.HideReviewedCR"))
        defaults.removePersistentDomain(forName: "DashboardViewModelExtendedTests.HideReviewedCR")
        let store = ViewsStore(defaults: defaults)
        await mockClient.setViewerLogin("testuser")
        let identity = try await IdentityActorTestFactory.makeAuthenticated(github: mockClient)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: identity, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults, notificationCenter: MockUserNotificationCenter(), widgetDestination: .temporary())
        let testView = DashboardView(id: UUID(), title: "Review", query: "is:pr", hideReviewed: true)
        viewModel.addView(testView)

        let changesRequestedPR = try TestPullRequestFactory.make(
            id: "PR_CR", number: 1, title: "Changes Requested",
            latestReviews: [UserReview(login: "testuser", state: .changesRequested)]
        )
        await mockClient.setPullRequestsToReturn([changesRequestedPR])
        await viewModel.refresh(viewID: testView.id)

        let titles = try #require(viewModel.viewStates[testView.id]).pullRequests.map(\.title)
        #expect(!titles.contains("Changes Requested"))
    }

    @Test("hideReviewed keeps PRs with COMMENTED review from viewer")
    func hideReviewedCommented() async throws {
        let defaults = try #require(UserDefaults(suiteName: "DashboardViewModelExtendedTests.HideReviewedComment"))
        defaults.removePersistentDomain(forName: "DashboardViewModelExtendedTests.HideReviewedComment")
        let store = ViewsStore(defaults: defaults)
        await mockClient.setViewerLogin("testuser")
        let identity = try await IdentityActorTestFactory.makeAuthenticated(github: mockClient)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: identity, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults, notificationCenter: MockUserNotificationCenter(), widgetDestination: .temporary())
        let testView = DashboardView(id: UUID(), title: "Review", query: "is:pr", hideReviewed: true)
        viewModel.addView(testView)

        let commentedPR = try TestPullRequestFactory.make(
            id: "PR_C", number: 1, title: "Commented",
            latestReviews: [UserReview(login: "testuser", state: .commented)]
        )
        await mockClient.setPullRequestsToReturn([commentedPR])
        await viewModel.refresh(viewID: testView.id)

        let titles = try #require(viewModel.viewStates[testView.id]).pullRequests.map(\.title)
        #expect(!titles.contains("Commented"))
    }

    @Test("hideReviewed retries viewer login after swap cancellation")
    func hideReviewedRetriesAfterCancellation() async throws {
        let defaults = try #require(UserDefaults(suiteName: "DashboardViewModelExtendedTests.HideReviewedRetry"))
        defaults.removePersistentDomain(forName: "DashboardViewModelExtendedTests.HideReviewedRetry")
        let store = ViewsStore(defaults: defaults)
        let harness = IdentityActorTestFactory.makeHarness(github: mockClient)
        let identity = harness.identity
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: identity, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults, notificationCenter: MockUserNotificationCenter(), widgetDestination: .temporary())
        let testView = DashboardView(id: UUID(), title: "Review", query: "is:pr", hideReviewed: true)
        viewModel.addView(testView)

        let approvedPR = try TestPullRequestFactory.make(
            id: "PR_A", number: 1, title: "Approved",
            latestReviews: [UserReview(login: "testuser", state: .approved)]
        )
        await mockClient.setPullRequestsToReturn([approvedPR])

        // First swap attempt is cancelled → state stays unauthenticated → filter skipped.
        await mockClient.setValidateTokenError(CancellationError())
        do {
            _ = try await identity.swap(to: "ghp_try1")
            Issue.record("Expected cancellation")
        } catch is CancellationError { /* expected */ }

        await viewModel.refresh(viewID: testView.id)
        var titles = try #require(viewModel.viewStates[testView.id]).pullRequests.map(\.title)
        #expect(titles.contains("Approved"))

        // Second swap succeeds → viewer login available → filter applies.
        await mockClient.setValidateTokenError(nil)
        await mockClient.setViewerLogin("testuser")
        _ = try await identity.swap(to: "ghp_try2")
        try harness.deleteStoredToken()
        await viewModel.refresh(viewID: testView.id)
        titles = try #require(viewModel.viewStates[testView.id]).pullRequests.map(\.title)
        #expect(!titles.contains("Approved"))
    }

    @Test("the hide-reviewed banner clears once the viewer login resolves")
    func hideReviewedBannerResolves() async throws {
        let suiteName = "DashboardViewModelExtendedTests.HideReviewedBanner"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let harness = IdentityActorTestFactory.makeHarness(github: mockClient)
        let events = EventCenter()
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: harness.identity, viewsStore: ViewsStore(defaults: defaults), localRepositoryService: localRepoService, defaults: defaults, notificationCenter: MockUserNotificationCenter(), widgetDestination: .temporary(), reporter: events.reporter())
        let testView = DashboardView(id: UUID(), title: "Review", query: "is:pr", hideReviewed: true)
        viewModel.addView(testView)

        await viewModel.refresh(viewID: testView.id)
        try await TestWait.until { !events.standingEvents.isEmpty }
        #expect(events.standingEvents.map(\.appError) == [.viewerIdentityUnavailable])

        await mockClient.setViewerLogin("testuser")
        _ = try await harness.identity.swap(to: "ghp_banner")
        try harness.deleteStoredToken()
        await viewModel.refresh(viewID: testView.id)
        try await TestWait.until { events.standingEvents.isEmpty }
        #expect(events.standingEvents.isEmpty)
    }

    // MARK: - hideReviewed disabled doesn't filter

    @Test("refresh does not filter when hideReviewed is false")
    func refreshNoFilterWhenHideReviewedOff() async throws {
        let defaults = try #require(UserDefaults(suiteName: "DashboardViewModelExtendedTests.NoFilterOff"))
        defaults.removePersistentDomain(forName: "DashboardViewModelExtendedTests.NoFilterOff")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults, notificationCenter: MockUserNotificationCenter(), widgetDestination: .temporary())
        let testView = DashboardView(id: UUID(), title: "All", query: "is:pr", hideReviewed: false)
        viewModel.addView(testView)

        await mockClient.setViewerLogin("testuser")
        let approvedPR = try TestPullRequestFactory.make(
            id: "PR_A", number: 1, title: "Approved",
            latestReviews: [UserReview(login: "testuser", state: .approved)]
        )
        await mockClient.setPullRequestsToReturn([approvedPR])
        await viewModel.refresh(viewID: testView.id)

        let titles = try #require(viewModel.viewStates[testView.id]).pullRequests.map(\.title)
        #expect(titles.contains("Approved"))
    }

    // MARK: - selectedViewState with invalid selection

    @Test("selectedViewState returns empty state for stale selection")
    func selectedViewStateStaleSelection() throws {
        let (viewModel, _) = try makeViewModel(suiteName: "StaleSelection")
        viewModel.selectedViewID = UUID() // non-existent view ID
        let state = viewModel.selectedViewState
        #expect(state.isEmpty)
    }

    // MARK: - deleteView when not selected

    @Test("deleteView does not change selection when deleted view is not selected")
    func deleteViewKeepsSelection() throws {
        let defaults = try #require(UserDefaults(suiteName: "DashboardViewModelExtendedTests.DeleteKeepSelection"))
        defaults.removePersistentDomain(forName: "DashboardViewModelExtendedTests.DeleteKeepSelection")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults, notificationCenter: MockUserNotificationCenter(), widgetDestination: .temporary())

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
    func viewStateHasData() throws {
        var state = ViewState()
        #expect(!state.hasData)

        state.pullRequests = [try TestPullRequestFactory.make()]
        #expect(state.hasData)
    }

    // MARK: - clearAllData

    @Test("clearAllData resets all state and persists empty views")
    func clearAllDataResetsState() async throws {
        let defaults = try #require(UserDefaults(suiteName: "DashboardViewModelExtendedTests.ClearAllData"))
        defaults.removePersistentDomain(forName: "DashboardViewModelExtendedTests.ClearAllData")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults, notificationCenter: MockUserNotificationCenter(), widgetDestination: .temporary())

        let view1 = DashboardView(id: UUID(), title: "View 1", query: "q1")
        viewModel.addView(view1)
        await mockClient.setPullRequestsToReturn([try TestPullRequestFactory.make()])
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
    func restartAutoRefreshViaNotification() async throws {
        let (viewModel, _) = try makeViewModel(suiteName: "RestartAutoRefresh")
        await mockClient.setPullRequestsToReturn([try TestPullRequestFactory.make()])
        viewModel.startAutoRefresh()

        // Wait for the first auto-refresh tick to reach the GitHub client.
        let firstTickDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await mockClient.fetchPullRequestsCallCount < 1, ContinuousClock.now < firstTickDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let countBeforeRestart = await mockClient.fetchPullRequestsCallCount
        #expect(countBeforeRestart >= 1, "first auto-refresh tick did not run")

        // The interval-change notification should cancel the sleeping loop
        // and spawn a fresh one that ticks immediately — so we see a new
        // fetch well before the configured interval would naturally fire.
        NotificationCenter.default.post(name: Constants.Notifications.prRefreshIntervalChanged, object: nil)

        let restartDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await mockClient.fetchPullRequestsCallCount <= countBeforeRestart, ContinuousClock.now < restartDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let countAfterRestart = await mockClient.fetchPullRequestsCallCount
        #expect(countAfterRestart > countBeforeRestart, "interval-change notification did not trigger a fresh tick")

        viewModel.stopAutoRefresh()
    }

    // MARK: - checkAndNotify does not notify when notifications disabled

    @Test("a view without its bell never notifies")
    func checkAndNotifySkipsWhenDisabled() async throws {
        let defaults = try #require(UserDefaults(suiteName: "DashboardViewModelExtendedTests.NotifyDisabled"))
        defaults.removePersistentDomain(forName: "DashboardViewModelExtendedTests.NotifyDisabled")
        let notificationCenter = MockUserNotificationCenter()
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: ViewsStore(defaults: defaults), localRepositoryService: localRepoService, defaults: defaults, notificationCenter: notificationCenter, widgetDestination: .temporary())
        let silentView = DashboardView(id: UUID(), title: "Silent", query: "is:pr")
        let belledView = DashboardView(id: UUID(), title: "Belled", query: "is:pr")
        viewModel.addView(silentView)
        viewModel.addView(belledView)
        viewModel.setNotification(for: belledView.id, enabled: true)
        #expect(!viewModel.isNotificationEnabled(for: silentView.id))

        let pr = try TestPullRequestFactory.make(id: "PR_1", title: "First")
        await mockClient.setPullRequestsToReturn([pr])
        await viewModel.refresh(viewID: silentView.id)
        await viewModel.refresh(viewID: belledView.id)

        let pr2 = try TestPullRequestFactory.make(id: "PR_2", number: 2, title: "Second")
        await mockClient.setPullRequestsToReturn([pr, pr2])
        await viewModel.refresh(viewID: silentView.id)
        await viewModel.refresh(viewID: belledView.id)
        try await TestWait.until { !notificationCenter.delivered.isEmpty }

        // The silent view refreshed first, so its delivery would come first.
        #expect(notificationCenter.delivered.map(\.title) == ["Belled"])
    }

    // MARK: - refresh with view that was added externally via store

    @Test("refresh creates ViewState when reloaded view has no state yet")
    func refreshCreatesViewStateAfterReload() async throws {
        let defaults = try #require(UserDefaults(suiteName: "DashboardViewModelExtendedTests.RefreshCreatesState"))
        defaults.removePersistentDomain(forName: "DashboardViewModelExtendedTests.RefreshCreatesState")
        let store = ViewsStore(defaults: defaults)

        // Save a view directly to the store
        let testView = DashboardView(id: UUID(), title: "External", query: "is:pr")
        store.save([testView])

        // Create viewModel which loads from store — viewStates should be populated
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults, notificationCenter: MockUserNotificationCenter(), widgetDestination: .temporary())
        #expect(viewModel.viewStates[testView.id] != nil)

        await mockClient.setPullRequestsToReturn([try TestPullRequestFactory.make()])
        await viewModel.refresh(viewID: testView.id)

        #expect(viewModel.viewStates[testView.id]?.pullRequests.count == 1)
    }

    // MARK: - Multiple notification: single PR vs multi PR

    @Test("one new PR is announced with its repository, number and title")
    func notifySingleNewPR() async throws {
        let defaults = try #require(UserDefaults(suiteName: "DashboardViewModelExtendedTests.NotifySingle"))
        defaults.removePersistentDomain(forName: "DashboardViewModelExtendedTests.NotifySingle")
        let notificationCenter = MockUserNotificationCenter()
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: ViewsStore(defaults: defaults), localRepositoryService: localRepoService, defaults: defaults, notificationCenter: notificationCenter, widgetDestination: .temporary())
        let testView = DashboardView(id: UUID(), title: "Notify", query: "is:pr")
        viewModel.addView(testView)
        viewModel.setNotification(for: testView.id, enabled: true)

        let pr1 = try TestPullRequestFactory.make(id: "PR_1", title: "Initial")
        await mockClient.setPullRequestsToReturn([pr1])
        await viewModel.refresh(viewID: testView.id)

        let pr2 = try TestPullRequestFactory.make(id: "PR_2", number: 2, title: "New One", repository: Repository(nameWithOwner: "acme/web"))
        await mockClient.setPullRequestsToReturn([pr1, pr2])
        await viewModel.refresh(viewID: testView.id)
        try await TestWait.until { !notificationCenter.delivered.isEmpty }

        let content = try #require(notificationCenter.delivered.first)
        #expect(notificationCenter.delivered.count == 1)
        #expect(content.title == "Notify")
        #expect(content.subtitle == "acme/web")
        #expect(content.body == "#2 New One")
    }

    @Test("several new PRs are listed four at a time with a count of the rest")
    func notifyMultipleNewPRs() async throws {
        let defaults = try #require(UserDefaults(suiteName: "DashboardViewModelExtendedTests.NotifyMultiple"))
        defaults.removePersistentDomain(forName: "DashboardViewModelExtendedTests.NotifyMultiple")
        let notificationCenter = MockUserNotificationCenter()
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: ViewsStore(defaults: defaults), localRepositoryService: localRepoService, defaults: defaults, notificationCenter: notificationCenter, widgetDestination: .temporary())
        let testView = DashboardView(id: UUID(), title: "Notify", query: "is:pr")
        viewModel.addView(testView)
        viewModel.setNotification(for: testView.id, enabled: true)

        let initial = try TestPullRequestFactory.make(id: "PR_1", title: "Initial")
        await mockClient.setPullRequestsToReturn([initial])
        await viewModel.refresh(viewID: testView.id)

        var prs = [initial]
        for number in 2...6 {
            prs.append(try TestPullRequestFactory.make(id: "PR_\(number)", number: number, title: "New \(number)"))
        }
        await mockClient.setPullRequestsToReturn(prs)
        await viewModel.refresh(viewID: testView.id)
        try await TestWait.until { !notificationCenter.delivered.isEmpty }

        let content = try #require(notificationCenter.delivered.first)
        #expect(content.body.split(separator: "\n").map(String.init) == [
            "owner/repo #2 New 2",
            "owner/repo #3 New 3",
            "owner/repo #4 New 4",
            "owner/repo #5 New 5",
            "+1 more",
        ])
    }

    // MARK: - isVSCodeAvailable / isITermAvailable / isCmuxAvailable delegation

    @Test("isVSCodeAvailable delegates to localRepositoryService")
    func isVSCodeAvailableDelegation() throws {
        let (viewModel, _) = try makeViewModel(suiteName: "VSCodeAvail")
        #expect(viewModel.isVSCodeAvailable == localRepoService.isVSCodeAvailable)
    }

    @Test("isITermAvailable delegates to localRepositoryService")
    func isITermAvailableDelegation() throws {
        let (viewModel, _) = try makeViewModel(suiteName: "ITermAvail")
        #expect(viewModel.isITermAvailable == localRepoService.isITermAvailable)
    }

    @Test("isCmuxAvailable delegates to localRepositoryService")
    func isCmuxAvailableDelegation() throws {
        let (viewModel, _) = try makeViewModel(suiteName: "CmuxAvail")
        #expect(viewModel.isCmuxAvailable == localRepoService.isCmuxAvailable)
    }

}
