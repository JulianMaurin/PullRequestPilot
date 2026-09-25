import Testing
import Foundation
@testable import PullRequestPilot

@MainActor
@Suite("DashboardViewModel")
struct DashboardViewModelTests {
    // Swift Testing creates a fresh struct instance per @Test method, so
    // each test gets its own mockClient and localRepoService.
    let mockClient = MockGitHubClient()
    let localRepoService = LocalRepositoryService()

    private func makeIdentity(suiteName: String) -> IdentityActor {
        let keychain = KeychainService(service: "com.pullrequestpilot.dashboard.tests.\(suiteName)")
        try? keychain.delete(key: Constants.Keychain.githubToken)
        return IdentityActor(keychain: keychain, github: mockClient)
    }

    private func makeViewModel(
        suiteName: String = "DashboardViewModelTests",
        reporter: EventReporter = .noop
    ) -> (viewModel: DashboardViewModel, viewID: UUID) {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = ViewsStore(defaults: defaults)
        let identity = makeIdentity(suiteName: suiteName)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: identity, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults, reporter: reporter)
        let testView = DashboardView(id: UUID(), title: "Test View", query: "is:pr is:open")
        viewModel.addView(testView)
        return (viewModel, testView.id)
    }

    @Test("loads pull requests for a view on refresh")
    func loadsPullRequests() async throws {
        let pr = makePullRequest(number: 1, title: "Fix bug")
        await mockClient.setPullRequestsToReturn([pr])

        let (viewModel, viewID) = makeViewModel(suiteName: "LoadsPRs")
        await viewModel.refresh(viewID: viewID)

        let state = try #require(viewModel.viewStates[viewID])
        #expect(state.pullRequests.count == 1)
        #expect(state.pullRequests.first?.title == "Fix bug")
        #expect(state.error == nil)
        #expect(!state.isLoading)
    }

    @Test("surfaces error message on failure")
    func handlesError() async throws {
        await mockClient.setErrorToThrow(GitHubClientError.unauthorized)

        let (viewModel, viewID) = makeViewModel(suiteName: "HandlesError")
        await viewModel.refresh(viewID: viewID)

        let state = try #require(viewModel.viewStates[viewID])
        #expect(state.pullRequests.isEmpty)
        #expect(state.error != nil)
    }

    @Test("isEmpty is true when no PRs and not loading")
    func isEmpty() async throws {
        await mockClient.setPullRequestsToReturn([])

        let (viewModel, viewID) = makeViewModel(suiteName: "IsEmpty")
        await viewModel.refresh(viewID: viewID)

        let state = try #require(viewModel.viewStates[viewID])
        #expect(state.isEmpty)
    }

    @Test("passes the view query to the client")
    func passesQueryToClient() async {
        let (viewModel, viewID) = makeViewModel(suiteName: "PassesQuery")
        let view = viewModel.views.first(where: { $0.id == viewID })
        await viewModel.refresh(viewID: viewID)

        #expect(await mockClient.receivedQueries.last == view?.query)
    }

    @Test("add and delete views")
    func addAndDeleteViews() {
        let (viewModel, _) = makeViewModel(suiteName: "AddDeleteViews")
        let initialCount = viewModel.views.count

        let newView = DashboardView(id: UUID(), title: "My PRs", query: "is:pr author:@me")
        viewModel.addView(newView)
        #expect(viewModel.views.count == initialCount + 1)

        viewModel.deleteView(id: newView.id)
        #expect(viewModel.views.count == initialCount)
    }

    @Test("hideReviewed filters out PRs with active reviews but keeps dismissed")
    func hideReviewedFiltering() async throws {
        let approvedPR = makePullRequest(number: 1, title: "Approved", reviews: [
            UserReview(login: "testuser", state: .approved)
        ])
        let dismissedPR = makePullRequest(number: 2, title: "Dismissed", reviews: [
            UserReview(login: "testuser", state: .dismissed)
        ])
        let unreviewedPR = makePullRequest(number: 3, title: "Unreviewed", reviews: [])
        let otherReviewPR = makePullRequest(number: 4, title: "Other reviewed", reviews: [
            UserReview(login: "someone-else", state: .approved)
        ])
        await mockClient.setPullRequestsToReturn([approvedPR, dismissedPR, unreviewedPR, otherReviewPR])

        let defaults = UserDefaults(suiteName: "HideReviewedTests")!
        defaults.removePersistentDomain(forName: "HideReviewedTests")
        let store = ViewsStore(defaults: defaults)
        await mockClient.setViewerLogin("testuser")
        let identity = try await IdentityActorTestFactory.makeAuthenticated(github: mockClient, token: "ghp_test_token")
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: identity, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        let testView = DashboardView(id: UUID(), title: "Review", query: "is:pr", hideReviewed: true)
        viewModel.addView(testView)
        let viewID = testView.id

        #expect(viewModel.views.first(where: { $0.id == viewID })?.hideReviewed == true)
        await viewModel.refresh(viewID: viewID)

        let state = viewModel.viewStates[viewID]
        let titles = state?.pullRequests.map(\.title) ?? []
        #expect(titles.contains("Dismissed"))
        #expect(titles.contains("Unreviewed"))
        #expect(titles.contains("Other reviewed"))
        #expect(!titles.contains("Approved"))
    }

    // MARK: - Network Error State

    @Test("refresh sets isNetworkError on network failure")
    func refreshSetsNetworkError() async throws {
        await mockClient.setErrorToThrow(GitHubClientError.networkError(URLError(.notConnectedToInternet)))

        let (viewModel, viewID) = makeViewModel(suiteName: "NetworkError")
        await viewModel.refresh(viewID: viewID)

        let state = try #require(viewModel.viewStates[viewID])
        #expect(state.isNetworkError)
        #expect(state.error != nil)
    }

    @Test("refresh clears isNetworkError on success after previous network error")
    func refreshClearsNetworkError() async throws {
        await mockClient.setErrorToThrow(GitHubClientError.networkError(URLError(.notConnectedToInternet)))

        let (viewModel, viewID) = makeViewModel(suiteName: "ClearsNetworkError")
        await viewModel.refresh(viewID: viewID)
        #expect(viewModel.viewStates[viewID]?.isNetworkError == true)

        await mockClient.setErrorToThrow(nil)
        await mockClient.setPullRequestsToReturn([makePullRequest(number: 1, title: "OK")])
        await viewModel.refresh(viewID: viewID)

        let state = try #require(viewModel.viewStates[viewID])
        #expect(!state.isNetworkError)
        #expect(state.error == nil)
    }

    @Test("isNetworkError is false for non-network errors")
    func nonNetworkErrorDoesNotSetFlag() async throws {
        await mockClient.setErrorToThrow(GitHubClientError.unauthorized)

        let (viewModel, viewID) = makeViewModel(suiteName: "NonNetworkError")
        await viewModel.refresh(viewID: viewID)

        let state = try #require(viewModel.viewStates[viewID])
        #expect(!state.isNetworkError)
        #expect(state.error != nil)
    }

    // MARK: - showingSettings

    @Test("showingSettings defaults to false")
    func showingSettingsDefault() {
        let (viewModel, _) = makeViewModel(suiteName: "SettingsDefault")
        #expect(!viewModel.showingSettings)
    }

    @Test("showingSettings can be toggled")
    func showingSettingsToggle() {
        let (viewModel, _) = makeViewModel(suiteName: "SettingsToggle")
        viewModel.showingSettings = true
        #expect(viewModel.showingSettings)
        viewModel.showingSettings = false
        #expect(!viewModel.showingSettings)
    }

    // MARK: - Selected View Persistence

    @Test("selectedViewID is persisted to UserDefaults on change")
    func selectedViewIDPersisted() {
        let defaults = UserDefaults(suiteName: "SelectedViewPersist")!
        defaults.removePersistentDomain(forName: "SelectedViewPersist")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        let view1 = DashboardView(id: UUID(), title: "View 1", query: "is:pr")
        let view2 = DashboardView(id: UUID(), title: "View 2", query: "is:pr")
        viewModel.addView(view1)
        viewModel.addView(view2)

        viewModel.selectedViewID = view2.id

        let stored = defaults.string(forKey: Constants.UserDefaultsKeys.selectedViewID)
        #expect(stored == view2.id.uuidString)
    }

    @Test("selectedViewID is restored from UserDefaults on init")
    func selectedViewIDRestored() {
        let defaults = UserDefaults(suiteName: "SelectedViewRestore")!
        defaults.removePersistentDomain(forName: "SelectedViewRestore")
        let store = ViewsStore(defaults: defaults)

        let view1 = DashboardView(id: UUID(), title: "View 1", query: "is:pr")
        let view2 = DashboardView(id: UUID(), title: "View 2", query: "is:pr")
        store.save([view1, view2])
        defaults.set(view2.id.uuidString, forKey: Constants.UserDefaultsKeys.selectedViewID)

        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        #expect(viewModel.selectedViewID == view2.id)
    }

    @Test("selectedViewID falls back to first view when stored ID is invalid")
    func selectedViewIDFallsBackOnInvalidID() {
        let defaults = UserDefaults(suiteName: "SelectedViewFallback")!
        defaults.removePersistentDomain(forName: "SelectedViewFallback")
        let store = ViewsStore(defaults: defaults)

        let view1 = DashboardView(id: UUID(), title: "View 1", query: "is:pr")
        store.save([view1])
        defaults.set(UUID().uuidString, forKey: Constants.UserDefaultsKeys.selectedViewID)

        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        #expect(viewModel.selectedViewID == view1.id)
    }

    @Test("clearAllData removes persisted selectedViewID")
    func clearAllDataRemovesSelectedViewID() {
        let defaults = UserDefaults(suiteName: "ClearSelectedView")!
        defaults.removePersistentDomain(forName: "ClearSelectedView")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        let view1 = DashboardView(id: UUID(), title: "View 1", query: "is:pr")
        viewModel.addView(view1)
        viewModel.selectedViewID = view1.id

        viewModel.clearAllData()

        let stored = defaults.string(forKey: Constants.UserDefaultsKeys.selectedViewID)
        #expect(stored == nil)
    }

    // MARK: - Badge Count

    @Test("badgeCount tracks unseen PRs that appear after initial load")
    func badgeCountTracksUnseen() async {
        let pr1 = makePullRequest(number: 1, title: "PR 1")
        let pr2 = makePullRequest(number: 2, title: "PR 2")

        let defaults = UserDefaults(suiteName: "BadgeUnseen")!
        defaults.removePersistentDomain(forName: "BadgeUnseen")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        let view1 = DashboardView(id: UUID(), title: "View 1", query: "is:pr")
        viewModel.addView(view1)
        viewModel.setBadge(for: view1.id, enabled: true)

        // First refresh = baseline, no unseen
        await mockClient.setPullRequestsToReturn([pr1])
        await viewModel.refresh(viewID: view1.id)
        #expect(viewModel.badgeCount == 0)

        // Second refresh with a new PR = 1 unseen
        await mockClient.setPullRequestsToReturn([pr1, pr2])
        await viewModel.refresh(viewID: view1.id)
        #expect(viewModel.badgeCount == 1)
    }

    @Test("badgeCount returns 0 when no views have badge enabled")
    func badgeCountZeroWhenNoneEnabled() async {
        await mockClient.setPullRequestsToReturn([makePullRequest(number: 1, title: "PR 1")])
        let (viewModel, viewID) = makeViewModel(suiteName: "BadgeCountNone")
        await viewModel.refresh(viewID: viewID)

        #expect(viewModel.badgeCount == 0)
    }

    @Test("markBadgeAsSeen resets badgeCount to zero")
    func markBadgeAsSeen() async {
        let pr1 = makePullRequest(number: 1, title: "PR 1")
        let pr2 = makePullRequest(number: 2, title: "PR 2")

        let defaults = UserDefaults(suiteName: "BadgeSeen")!
        defaults.removePersistentDomain(forName: "BadgeSeen")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        let view1 = DashboardView(id: UUID(), title: "View 1", query: "is:pr")
        viewModel.addView(view1)
        viewModel.setBadge(for: view1.id, enabled: true)

        await mockClient.setPullRequestsToReturn([pr1])
        await viewModel.refresh(viewID: view1.id)
        await mockClient.setPullRequestsToReturn([pr1, pr2])
        await viewModel.refresh(viewID: view1.id)
        #expect(viewModel.badgeCount == 1)

        viewModel.markBadgeAsSeen()
        #expect(viewModel.badgeCount == 0)
    }

    @Test("isBadgeEnabled and setBadge toggle correctly")
    func badgeToggle() {
        let (viewModel, viewID) = makeViewModel(suiteName: "DashboardViewModelTests.BadgeToggle")

        #expect(!viewModel.isBadgeEnabled(for: viewID))
        viewModel.setBadge(for: viewID, enabled: true)
        #expect(viewModel.isBadgeEnabled(for: viewID))
        viewModel.setBadge(for: viewID, enabled: false)
        #expect(!viewModel.isBadgeEnabled(for: viewID))
    }

    @Test("setBadge sets baseline so existing PRs are not counted as new")
    func setBadgeBaseline() async {
        await mockClient.setPullRequestsToReturn([makePullRequest(number: 1, title: "PR 1")])
        let defaults = UserDefaults(suiteName: "BadgeBaseline")!
        defaults.removePersistentDomain(forName: "BadgeBaseline")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        let view1 = DashboardView(id: UUID(), title: "View 1", query: "is:pr")
        viewModel.addView(view1)

        // Load PRs first, then enable badge
        await viewModel.refresh(viewID: view1.id)
        viewModel.setBadge(for: view1.id, enabled: true)

        // Re-refresh with same PRs — should be 0 unseen
        await viewModel.refresh(viewID: view1.id)
        #expect(viewModel.badgeCount == 0)
    }

    @Test("badgeViewIDs persists to UserDefaults")
    func badgeViewIDsPersisted() {
        let defaults = UserDefaults(suiteName: "BadgePersist")!
        defaults.removePersistentDomain(forName: "BadgePersist")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        let view1 = DashboardView(id: UUID(), title: "View 1", query: "is:pr")
        viewModel.addView(view1)

        viewModel.setBadge(for: view1.id, enabled: true)

        let stored = Set(defaults.stringArray(forKey: Constants.UserDefaultsKeys.badgeViewIDs) ?? [])
        #expect(stored.contains(view1.id.uuidString))
    }

    @Test("badgeViewIDs restores from UserDefaults on init")
    func badgeViewIDsRestored() {
        let defaults = UserDefaults(suiteName: "BadgeRestore")!
        defaults.removePersistentDomain(forName: "BadgeRestore")
        let viewID = UUID()
        defaults.set([viewID.uuidString], forKey: Constants.UserDefaultsKeys.badgeViewIDs)
        let store = ViewsStore(defaults: defaults)

        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        #expect(viewModel.isBadgeEnabled(for: viewID))
    }

    @Test("clearAllData clears badgeViewIDs and unseen count")
    func clearAllDataClearsBadge() async {
        let defaults = UserDefaults(suiteName: "ClearBadge")!
        defaults.removePersistentDomain(forName: "ClearBadge")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        let view1 = DashboardView(id: UUID(), title: "View 1", query: "is:pr")
        viewModel.addView(view1)
        viewModel.setBadge(for: view1.id, enabled: true)

        viewModel.clearAllData()
        #expect(viewModel.badgeTracker.enabledViewIDs.isEmpty)
        #expect(viewModel.badgeCount == 0)
    }

    @Test("onBadgeCountChanged is called when new PRs appear")
    func badgeCallbackOnNewPRs() async {
        let pr1 = makePullRequest(number: 1, title: "PR 1")
        let pr2 = makePullRequest(number: 2, title: "PR 2")

        let defaults = UserDefaults(suiteName: "DashboardViewModelTests.BadgeCallback")!
        defaults.removePersistentDomain(forName: "DashboardViewModelTests.BadgeCallback")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        let view1 = DashboardView(id: UUID(), title: "View 1", query: "is:pr")
        viewModel.addView(view1)
        viewModel.setBadge(for: view1.id, enabled: true)

        // Baseline refresh
        await mockClient.setPullRequestsToReturn([pr1])
        await viewModel.refresh(viewID: view1.id)

        // Now listen for callback when new PR appears
        var receivedCount: Int?
        viewModel.onBadgeCountChanged = { count in receivedCount = count }
        await mockClient.setPullRequestsToReturn([pr1, pr2])
        await viewModel.refresh(viewID: view1.id)

        #expect(receivedCount == 1)
    }

    @Test("deleteView removes view from badgeViewIDs")
    func deleteViewRemovesBadge() {
        let defaults = UserDefaults(suiteName: "DeleteBadge")!
        defaults.removePersistentDomain(forName: "DeleteBadge")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        let view1 = DashboardView(id: UUID(), title: "View 1", query: "is:pr")
        viewModel.addView(view1)
        viewModel.setBadge(for: view1.id, enabled: true)

        viewModel.deleteView(id: view1.id)
        #expect(!viewModel.isBadgeEnabled(for: view1.id))
    }

    @Test("deleteView prunes unseen badge PRs from deleted view")
    func deleteViewPrunesUnseenBadgePRs() async {
        let pr1 = makePullRequest(number: 1, title: "PR 1")
        let pr2 = makePullRequest(number: 2, title: "PR 2")

        let defaults = UserDefaults(suiteName: "DeletePrunes")!
        defaults.removePersistentDomain(forName: "DeletePrunes")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        let view1 = DashboardView(id: UUID(), title: "View 1", query: "is:pr")
        viewModel.addView(view1)
        viewModel.setBadge(for: view1.id, enabled: true)

        // Baseline + new PR to create unseen badge count
        await mockClient.setPullRequestsToReturn([pr1])
        await viewModel.refresh(viewID: view1.id)
        await mockClient.setPullRequestsToReturn([pr1, pr2])
        await viewModel.refresh(viewID: view1.id)
        #expect(viewModel.badgeCount == 1)

        // Delete the view — badge count should drop to 0
        viewModel.deleteView(id: view1.id)
        #expect(viewModel.badgeCount == 0)
    }

    @Test("swapping token refreshes viewer login so filter uses the new user")
    func tokenSwapResetsViewerLoginForFilter() async throws {
        let defaults = UserDefaults(suiteName: "SwapViewer")!
        defaults.removePersistentDomain(forName: "SwapViewer")
        let store = ViewsStore(defaults: defaults)
        let harness = IdentityActorTestFactory.makeHarness(github: mockClient)
        let identity = harness.identity
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: identity, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        let testView = DashboardView(id: UUID(), title: "Review", query: "is:pr", hideReviewed: true)
        viewModel.addView(testView)

        // First identity: "testuser"
        await mockClient.setViewerLogin("testuser")
        _ = try await identity.swap(to: "ghp_first")
        try harness.deleteStoredToken()

        let approvedPR = makePullRequest(number: 1, title: "Approved", reviews: [
            UserReview(login: "testuser", state: .approved)
        ])
        await mockClient.setPullRequestsToReturn([approvedPR])
        await viewModel.refresh(viewID: testView.id)
        // Filtered out — "testuser" already approved.
        #expect(viewModel.viewStates[testView.id]?.pullRequests.isEmpty == true)

        // Swap to second identity: "otheruser"
        await mockClient.setViewerLogin("otheruser")
        _ = try await identity.swap(to: "ghp_second")
        try harness.deleteStoredToken()

        await viewModel.refresh(viewID: testView.id)
        // Visible — the new user hasn't reviewed it, regression from 802d1bc9.
        #expect(viewModel.viewStates[testView.id]?.pullRequests.count == 1)
    }

    // MARK: - View Navigation

    @Test("markBadgeAsSeenForSelectedView clears only the selected view's unseen PRs")
    func markBadgeAsSeenForSelectedView() async {
        let pr1 = makePullRequest(number: 1, title: "PR 1")
        let pr2 = makePullRequest(number: 2, title: "PR 2")
        let pr3 = makePullRequest(number: 3, title: "PR 3")

        let defaults = UserDefaults(suiteName: "BadgeSeenPerView")!
        defaults.removePersistentDomain(forName: "BadgeSeenPerView")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        let view1 = DashboardView(id: UUID(), title: "View 1", query: "is:pr")
        let view2 = DashboardView(id: UUID(), title: "View 2", query: "is:pr")
        viewModel.addView(view1)
        viewModel.addView(view2)
        viewModel.setBadge(for: view1.id, enabled: true)
        viewModel.setBadge(for: view2.id, enabled: true)

        // Baseline refresh for both views
        await mockClient.setPullRequestsToReturn([pr1])
        await viewModel.refresh(viewID: view1.id)
        await mockClient.setPullRequestsToReturn([pr2])
        await viewModel.refresh(viewID: view2.id)
        #expect(viewModel.badgeCount == 0)

        // Add new PRs to both views
        await mockClient.setPullRequestsToReturn([pr1, pr3])
        await viewModel.refresh(viewID: view1.id)
        await mockClient.setPullRequestsToReturn([pr2, pr3])
        await viewModel.refresh(viewID: view2.id)
        #expect(viewModel.badgeCount == 1) // PR_3 added to both, tracked once

        // Select view1 — should clear PR_3 since it's visible there
        viewModel.selectedViewID = view1.id
        #expect(viewModel.badgeCount == 0)
    }

    @Test("switching views clears badge for the newly selected view only")
    func switchingViewsClearsBadgePerView() async {
        let pr1 = makePullRequest(number: 1, title: "PR 1")
        let pr2 = makePullRequest(number: 2, title: "PR 2")
        let pr3 = makePullRequest(number: 3, title: "PR 3")
        let pr4 = makePullRequest(number: 4, title: "PR 4")

        let defaults = UserDefaults(suiteName: "BadgeSwitchView")!
        defaults.removePersistentDomain(forName: "BadgeSwitchView")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        let view1 = DashboardView(id: UUID(), title: "View 1", query: "is:pr")
        let view2 = DashboardView(id: UUID(), title: "View 2", query: "is:pr")
        viewModel.addView(view1)
        viewModel.addView(view2)
        viewModel.setBadge(for: view1.id, enabled: true)
        viewModel.setBadge(for: view2.id, enabled: true)

        // Baseline
        await mockClient.setPullRequestsToReturn([pr1])
        await viewModel.refresh(viewID: view1.id)
        await mockClient.setPullRequestsToReturn([pr2])
        await viewModel.refresh(viewID: view2.id)

        // New unique PRs in each view
        await mockClient.setPullRequestsToReturn([pr1, pr3])
        await viewModel.refresh(viewID: view1.id)
        await mockClient.setPullRequestsToReturn([pr2, pr4])
        await viewModel.refresh(viewID: view2.id)
        #expect(viewModel.badgeCount == 2)

        // Visit view1 — clears PR_3 but not PR_4
        viewModel.selectedViewID = view1.id
        #expect(viewModel.badgeCount == 1)
        #expect(viewModel.badgeTracker.unseenPRIDs == Set(["PR_4"]))

        // Visit view2 — clears PR_4
        viewModel.selectedViewID = view2.id
        #expect(viewModel.badgeCount == 0)
    }

    @Test("selectNextView cycles to next view")
    func selectNextView() {
        let defaults = UserDefaults(suiteName: "SelectNextView")!
        defaults.removePersistentDomain(forName: "SelectNextView")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        let view1 = DashboardView(id: UUID(), title: "View 1", query: "is:pr")
        let view2 = DashboardView(id: UUID(), title: "View 2", query: "is:pr")
        let view3 = DashboardView(id: UUID(), title: "View 3", query: "is:pr")
        viewModel.addView(view1)
        viewModel.addView(view2)
        viewModel.addView(view3)
        viewModel.selectedViewID = view1.id

        viewModel.selectNextView()
        #expect(viewModel.selectedViewID == view2.id)

        viewModel.selectNextView()
        #expect(viewModel.selectedViewID == view3.id)
    }

    @Test("selectNextView wraps around to first view")
    func selectNextViewWraps() {
        let defaults = UserDefaults(suiteName: "SelectNextViewWrap")!
        defaults.removePersistentDomain(forName: "SelectNextViewWrap")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        let view1 = DashboardView(id: UUID(), title: "View 1", query: "is:pr")
        let view2 = DashboardView(id: UUID(), title: "View 2", query: "is:pr")
        viewModel.addView(view1)
        viewModel.addView(view2)
        viewModel.selectedViewID = view2.id

        viewModel.selectNextView()
        #expect(viewModel.selectedViewID == view1.id)
    }

    @Test("selectPreviousView cycles to previous view")
    func selectPreviousView() {
        let defaults = UserDefaults(suiteName: "SelectPrevView")!
        defaults.removePersistentDomain(forName: "SelectPrevView")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        let view1 = DashboardView(id: UUID(), title: "View 1", query: "is:pr")
        let view2 = DashboardView(id: UUID(), title: "View 2", query: "is:pr")
        let view3 = DashboardView(id: UUID(), title: "View 3", query: "is:pr")
        viewModel.addView(view1)
        viewModel.addView(view2)
        viewModel.addView(view3)
        viewModel.selectedViewID = view3.id

        viewModel.selectPreviousView()
        #expect(viewModel.selectedViewID == view2.id)

        viewModel.selectPreviousView()
        #expect(viewModel.selectedViewID == view1.id)
    }

    @Test("selectPreviousView wraps around to last view")
    func selectPreviousViewWraps() {
        let defaults = UserDefaults(suiteName: "SelectPrevViewWrap")!
        defaults.removePersistentDomain(forName: "SelectPrevViewWrap")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        let view1 = DashboardView(id: UUID(), title: "View 1", query: "is:pr")
        let view2 = DashboardView(id: UUID(), title: "View 2", query: "is:pr")
        viewModel.addView(view1)
        viewModel.addView(view2)
        viewModel.selectedViewID = view1.id

        viewModel.selectPreviousView()
        #expect(viewModel.selectedViewID == view2.id)
    }

    @Test("selectNextView is no-op when no views exist")
    func selectNextViewNoViews() {
        let defaults = UserDefaults(suiteName: "SelectNextNoViews")!
        defaults.removePersistentDomain(forName: "SelectNextNoViews")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        viewModel.selectedViewID = nil

        viewModel.selectNextView()
        #expect(viewModel.selectedViewID == nil)
    }

    // MARK: - Collapsed Sections Persistence

    @Test("collapsedOrgs is persisted to UserDefaults on change")
    func collapsedOrgsPersisted() {
        let defaults = UserDefaults(suiteName: "CollapsedOrgsPersist")!
        defaults.removePersistentDomain(forName: "CollapsedOrgsPersist")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)

        viewModel.collapsedOrgs.insert("my-org")
        viewModel.collapsedOrgs.insert("other-org")

        let stored = Set(defaults.stringArray(forKey: Constants.UserDefaultsKeys.collapsedOrgs) ?? [])
        #expect(stored == Set(["my-org", "other-org"]))
    }

    @Test("collapsedRepos is persisted to UserDefaults on change")
    func collapsedReposPersisted() {
        let defaults = UserDefaults(suiteName: "CollapsedReposPersist")!
        defaults.removePersistentDomain(forName: "CollapsedReposPersist")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)

        viewModel.collapsedRepos.insert("my-org/repo-a")

        let stored = Set(defaults.stringArray(forKey: Constants.UserDefaultsKeys.collapsedRepos) ?? [])
        #expect(stored == Set(["my-org/repo-a"]))
    }

    @Test("collapsed sections are restored from UserDefaults on init")
    func collapsedSectionsRestored() {
        let defaults = UserDefaults(suiteName: "CollapsedRestore")!
        defaults.removePersistentDomain(forName: "CollapsedRestore")
        defaults.set(["org-a", "org-b"], forKey: Constants.UserDefaultsKeys.collapsedOrgs)
        defaults.set(["org-a/repo-1"], forKey: Constants.UserDefaultsKeys.collapsedRepos)

        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)

        #expect(viewModel.collapsedOrgs == Set(["org-a", "org-b"]))
        #expect(viewModel.collapsedRepos == Set(["org-a/repo-1"]))
    }

    @Test("clearAllData resets collapsed sections")
    func clearAllDataResetsCollapsedSections() {
        let defaults = UserDefaults(suiteName: "ClearCollapsed")!
        defaults.removePersistentDomain(forName: "ClearCollapsed")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)

        viewModel.collapsedOrgs.insert("some-org")
        viewModel.collapsedRepos.insert("some-org/repo")
        viewModel.clearAllData()

        #expect(viewModel.collapsedOrgs.isEmpty)
        #expect(viewModel.collapsedRepos.isEmpty)
    }

    // MARK: - Draft State

    @Test("setDraft sends the change, confirms it, and refreshes the views")
    func setDraftSuccess() async throws {
        let recorder = EventRecorder()
        let (viewModel, viewID) = makeViewModel(suiteName: "SetDraftSuccess", reporter: recorder.reporter())
        let pr = makePullRequest(number: 42, title: "Work in progress")
        await mockClient.setPullRequestsToReturn([pr])

        await viewModel.setDraft(pr, isDraft: true)

        #expect(await mockClient.receivedDraftStateRequests == [.init(pullRequestID: "PR_42", isDraft: true)])
        #expect(await mockClient.fetchPullRequestsCallCount == 1)
        #expect(recorder.events.map(\.message) == ["#42 converted to draft."])
        let state = try #require(viewModel.viewStates[viewID])
        #expect(state.pullRequests.map(\.id) == ["PR_42"])
    }

    @Test("setDraft refused by GitHub reports the reason and skips the refresh")
    func setDraftRefused() async throws {
        let recorder = EventRecorder()
        let (viewModel, _) = makeViewModel(suiteName: "SetDraftRefused", reporter: recorder.reporter())
        let pr = makePullRequest(number: 42, title: "Draft")
        await mockClient.setSetDraftError(GitHubClientError.graphQLErrors(["Resource not accessible by personal access token"]))

        await viewModel.setDraft(pr, isDraft: false)

        #expect(await mockClient.fetchPullRequestsCallCount == 0)
        #expect(recorder.events.count == 1)
        let event = try #require(recorder.events.first)
        #expect(event.appError == .draftStateChangeFailed(
            pullRequestNumber: 42,
            isDraft: false,
            detail: "Resource not accessible by personal access token"
        ))
        #expect(event.message == "Couldn't mark #42 as ready for review: Resource not accessible by personal access token")
    }

    @Test("setDraft with an invalid token posts the token error")
    func setDraftUnauthorized() async throws {
        let recorder = EventRecorder()
        let (viewModel, _) = makeViewModel(suiteName: "SetDraftUnauthorized", reporter: recorder.reporter())
        await mockClient.setSetDraftError(GitHubClientError.unauthorized)

        await viewModel.setDraft(makePullRequest(number: 7, title: "Feature"), isDraft: true)

        #expect(recorder.events.map(\.appError) == [.unauthorized])
        #expect(await mockClient.fetchPullRequestsCallCount == 0)
    }

    @Test("setDraft cancelled posts nothing and skips the refresh")
    func setDraftCancelled() async throws {
        let recorder = EventRecorder()
        let (viewModel, _) = makeViewModel(suiteName: "SetDraftCancelled", reporter: recorder.reporter())
        await mockClient.setSetDraftError(CancellationError())

        await viewModel.setDraft(makePullRequest(number: 7, title: "Feature"), isDraft: true)

        #expect(recorder.events.isEmpty)
        #expect(await mockClient.fetchPullRequestsCallCount == 0)
    }

    // MARK: - Helpers

    private func makePullRequest(number: Int, title: String, reviews: [UserReview] = []) -> PullRequest {
        PullRequest(
            id: "PR_\(number)",
            number: number,
            title: title,
            url: URL(string: "https://github.com/owner/repo/pull/\(number)")!,
            repository: Repository(nameWithOwner: "owner/repo"),
            author: Author(login: "author", avatarURL: nil),
            createdAt: Date().addingTimeInterval(-3600),
            updatedAt: Date(),
            additions: 10,
            deletions: 5,
            state: .open,
            isDraft: false,
            checkStatus: .success,
            reviewDecision: .reviewRequired,
            totalThreads: 0,
            unresolvedThreads: 0,
            labels: [],
            baseRefName: "main",
            headRefName: "feature-\(number)",
            headCommitSha: nil,
            isCrossRepository: false,
            lastActivity: nil,
            latestReviews: reviews
        )
    }
}
