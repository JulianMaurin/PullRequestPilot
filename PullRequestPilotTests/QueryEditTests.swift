import Testing
import Foundation
@testable import PullRequestPilot

@MainActor
@Suite("DashboardViewModel.commitQueryEdit & appendFilter")
struct QueryEditTests {
    private let mockClient = MockGitHubClient()
    private let localRepoService = LocalRepositoryService()

    private func makeViewModel(suiteName: String) throws -> (vm: DashboardViewModel, viewID: UUID) {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = ViewsStore(defaults: defaults)
        let vm = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults, notificationCenter: MockUserNotificationCenter(), widgetDestination: .temporary())
        let view = DashboardView(id: UUID(), title: "Test", query: "is:pr is:open")
        vm.addView(view)
        return (vm, view.id)
    }

    /// Shows the old query's rows, then serves `newRows` to the next fetch.
    private func loadOldRows(_ vm: DashboardViewModel, viewID: UUID, thenServe newRows: [PullRequest]) async throws {
        await mockClient.setPullRequestsToReturn([try TestPullRequestFactory.make(id: "PR_old")])
        await vm.refresh(viewID: viewID)
        #expect(vm.viewStates[viewID]?.pullRequests.map(\.id) == ["PR_old"])
        await mockClient.setPullRequestsToReturn(newRows)
    }

    // MARK: - commitQueryEdit

    @Test("commitQueryEdit drops the old rows and refetches with the new query")
    func commitQueryEditUpdates() async throws {
        let (vm, viewID) = try makeViewModel(suiteName: "QEditUpdates")
        try await loadOldRows(vm, viewID: viewID, thenServe: [try TestPullRequestFactory.make(id: "PR_new")])

        vm.commitQueryEdit(viewID: viewID, newQuery: "is:pr author:@me")

        #expect(vm.views.first(where: { $0.id == viewID })?.query == "is:pr author:@me")
        #expect(vm.viewStates[viewID]?.pullRequests.isEmpty == true, "the old query's rows must not linger")
        try await TestWait.until { vm.viewStates[viewID]?.pullRequests.map(\.id) == ["PR_new"] }
        #expect(vm.viewStates[viewID]?.pullRequests.map(\.id) == ["PR_new"])
        #expect(await mockClient.receivedQueries.last == "is:pr author:@me")
    }

    @Test("commitQueryEdit trims whitespace")
    func commitQueryEditTrims() throws {
        let (vm, viewID) = try makeViewModel(suiteName: "QEditTrims")
        vm.commitQueryEdit(viewID: viewID, newQuery: "  is:pr author:@me  \n")
        #expect(vm.views.first(where: { $0.id == viewID })?.query == "is:pr author:@me")
    }

    @Test("commitQueryEdit is no-op when empty after trim")
    func commitQueryEditIgnoresEmpty() throws {
        let (vm, viewID) = try makeViewModel(suiteName: "QEditEmpty")
        let original = vm.views.first(where: { $0.id == viewID })?.query
        vm.commitQueryEdit(viewID: viewID, newQuery: "   ")
        #expect(vm.views.first(where: { $0.id == viewID })?.query == original)
    }

    @Test("commitQueryEdit with the unchanged query neither resets nor refetches")
    func commitQueryEditIgnoresSame() async throws {
        let (vm, viewID) = try makeViewModel(suiteName: "QEditSame")
        try await loadOldRows(vm, viewID: viewID, thenServe: [try TestPullRequestFactory.make(id: "PR_new")])
        let original = try #require(vm.views.first(where: { $0.id == viewID })?.query)

        vm.commitQueryEdit(viewID: viewID, newQuery: original)
        #expect(vm.viewStates[viewID]?.pullRequests.map(\.id) == ["PR_old"])

        // A real edit afterwards is the barrier: any refetch the no-op had
        // scheduled would show up before it.
        vm.commitQueryEdit(viewID: viewID, newQuery: "is:pr is:merged")
        try await TestWait.until { vm.viewStates[viewID]?.pullRequests.map(\.id) == ["PR_new"] }
        #expect(await mockClient.receivedQueries == [original, "is:pr is:merged"])
    }

    @Test("commitQueryEdit is no-op for invalid viewID")
    func commitQueryEditInvalidView() throws {
        let (vm, viewID) = try makeViewModel(suiteName: "QEditInvalid")
        vm.commitQueryEdit(viewID: UUID(), newQuery: "is:pr")
        #expect(vm.views.first(where: { $0.id == viewID })?.query == "is:pr is:open")
    }

    // MARK: - appendFilter

    @Test("appendFilter appends the qualifier, drops the old rows and refetches")
    func appendFilterAppends() async throws {
        let (vm, viewID) = try makeViewModel(suiteName: "FilterAppend")
        try await loadOldRows(vm, viewID: viewID, thenServe: [try TestPullRequestFactory.make(id: "PR_new")])

        vm.appendFilter(viewID: viewID, qualifier: "org:acme")

        #expect(vm.views.first(where: { $0.id == viewID })?.query == "is:pr is:open org:acme")
        #expect(vm.viewStates[viewID]?.pullRequests.isEmpty == true)
        try await TestWait.until { vm.viewStates[viewID]?.pullRequests.map(\.id) == ["PR_new"] }
        #expect(await mockClient.receivedQueries.last == "is:pr is:open org:acme")
    }

    @Test("toggleHideReviewed drops the old rows and refetches")
    func toggleHideReviewedRefetches() async throws {
        let (vm, viewID) = try makeViewModel(suiteName: "ToggleHideReviewedRefetch")
        try await loadOldRows(vm, viewID: viewID, thenServe: [try TestPullRequestFactory.make(id: "PR_new")])

        vm.toggleHideReviewed(for: viewID)

        #expect(vm.views.first(where: { $0.id == viewID })?.hideReviewed == true)
        #expect(vm.viewStates[viewID]?.pullRequests.isEmpty == true)
        try await TestWait.until { await mockClient.fetchPullRequestsCallCount == 2 }
        #expect(await mockClient.fetchPullRequestsCallCount == 2)
    }

    @Test("appendFilter skips if qualifier already present")
    func appendFilterSkipsDuplicate() throws {
        let (vm, viewID) = try makeViewModel(suiteName: "FilterDup")
        vm.appendFilter(viewID: viewID, qualifier: "is:pr")
        #expect(vm.views.first(where: { $0.id == viewID })?.query == "is:pr is:open")
    }

    @Test("appendFilter is no-op for invalid viewID")
    func appendFilterInvalidView() throws {
        let (vm, viewID) = try makeViewModel(suiteName: "FilterInvalid")
        vm.appendFilter(viewID: UUID(), qualifier: "org:acme")
        #expect(vm.views.first(where: { $0.id == viewID })?.query == "is:pr is:open")
    }

    @Test("appendFilter appends negated qualifier and dedupes on repeat")
    func appendFilterNegated() throws {
        let (vm, viewID) = try makeViewModel(suiteName: "FilterAppendNegated")
        vm.appendFilter(viewID: viewID, qualifier: "-author:alice")
        #expect(vm.views.first(where: { $0.id == viewID })?.query == "is:pr is:open -author:alice")
        vm.appendFilter(viewID: viewID, qualifier: "-author:alice")
        #expect(vm.views.first(where: { $0.id == viewID })?.query == "is:pr is:open -author:alice")
    }

    // MARK: - queryContainsFilter

    @Test("queryContainsFilter returns true when qualifier exists")
    func queryContainsFilterTrue() throws {
        let (vm, viewID) = try makeViewModel(suiteName: "ContainsFilterTrue")
        vm.selectedViewID = viewID
        #expect(vm.queryContainsFilter(qualifier: "is:pr"))
    }

    @Test("queryContainsFilter returns false when qualifier absent")
    func queryContainsFilterFalse() throws {
        let (vm, viewID) = try makeViewModel(suiteName: "ContainsFilterFalse")
        vm.selectedViewID = viewID
        #expect(!vm.queryContainsFilter(qualifier: "org:acme"))
    }

    @Test("queryContainsFilter returns false when no view selected")
    func queryContainsFilterNoSelection() throws {
        let (vm, _) = try makeViewModel(suiteName: "ContainsFilterNone")
        vm.selectedViewID = nil
        #expect(!vm.queryContainsFilter(qualifier: "is:pr"))
    }

    @Test("queryContainsFilter distinguishes negated from positive qualifier")
    func queryContainsFilterNegated() throws {
        let (vm, viewID) = try makeViewModel(suiteName: "ContainsFilterNegated")
        vm.selectedViewID = viewID
        vm.appendFilter(viewID: viewID, qualifier: "-author:alice")
        #expect(vm.queryContainsFilter(qualifier: "-author:alice"))
        #expect(!vm.queryContainsFilter(qualifier: "author:alice"))
    }
}
