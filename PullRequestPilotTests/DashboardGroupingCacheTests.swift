import Testing
import Foundation
@testable import PullRequestPilot

@Suite("DashboardViewModel.groupedSelected memoization")
struct DashboardGroupingCacheTests {

    // MARK: - Helpers

    @MainActor
    private static func makeViewModel(suiteName: String) -> (DashboardViewModel, MockGitHubClient, UserDefaults) {
        let defaults = UserDefaults(suiteName: "DashboardGroupingCacheTests.\(suiteName)")!
        defaults.removePersistentDomain(forName: "DashboardGroupingCacheTests.\(suiteName)")
        let mock = MockGitHubClient()
        let store = ViewsStore(defaults: defaults)
        let identity = IdentityActorTestFactory.make(github: mock)
        let localRepo = LocalRepositoryService()
        let viewModel = DashboardViewModel(
            gitHubClient: mock,
            identity: identity,
            viewsStore: store,
            localRepositoryService: localRepo,
            defaults: defaults
        )
        return (viewModel, mock, defaults)
    }

    @MainActor
    private static func addViewAndRefresh(
        _ viewModel: DashboardViewModel,
        title: String,
        prs: [PullRequest],
        mock: MockGitHubClient
    ) async -> DashboardView {
        let view = DashboardView(id: UUID(), title: title, query: "is:pr")
        viewModel.addView(view)
        mock.pullRequestsToReturn = prs
        await viewModel.refresh(viewID: view.id)
        return view
    }

    // MARK: - Tests

    @MainActor
    @Test("repeated reads with an unchanged PR list hit the cache")
    func cacheHitOnRepeatReads() async throws {
        let (vm, mock, _) = Self.makeViewModel(suiteName: "Hit")
        _ = await Self.addViewAndRefresh(
            vm,
            title: "A",
            prs: [TestPullRequestFactory.make(id: "PR_1", title: "one")],
            mock: mock
        )
        #expect(vm.groupedRecomputeCount == 0)
        _ = vm.groupedSelected
        #expect(vm.groupedRecomputeCount == 1)
        _ = vm.groupedSelected
        _ = vm.groupedSelected
        _ = vm.groupedSelected
        #expect(vm.groupedRecomputeCount == 1, "grouping recomputed despite unchanged PR list")
    }

    @MainActor
    @Test("a refreshed PR list invalidates the cache")
    func cacheMissOnPRListChange() async throws {
        let (vm, mock, _) = Self.makeViewModel(suiteName: "PRChange")
        let view = await Self.addViewAndRefresh(
            vm,
            title: "A",
            prs: [TestPullRequestFactory.make(id: "PR_1", title: "one")],
            mock: mock
        )
        _ = vm.groupedSelected
        #expect(vm.groupedRecomputeCount == 1)
        // Refresh with a different list; the cache must miss.
        mock.pullRequestsToReturn = [
            TestPullRequestFactory.make(id: "PR_1", title: "one"),
            TestPullRequestFactory.make(id: "PR_2", title: "two"),
        ]
        await vm.refresh(viewID: view.id)
        _ = vm.groupedSelected
        #expect(vm.groupedRecomputeCount == 2)
    }

    @MainActor
    @Test("switching the selected view invalidates the cache")
    func cacheMissOnViewIDChange() async throws {
        let (vm, mock, _) = Self.makeViewModel(suiteName: "ViewChange")
        let viewA = await Self.addViewAndRefresh(
            vm,
            title: "A",
            prs: [TestPullRequestFactory.make(id: "PR_A1", title: "a1")],
            mock: mock
        )
        let viewB = await Self.addViewAndRefresh(
            vm,
            title: "B",
            prs: [TestPullRequestFactory.make(id: "PR_B1", title: "b1")],
            mock: mock
        )
        vm.selectedViewID = viewA.id
        _ = vm.groupedSelected
        let countAfterA = vm.groupedRecomputeCount
        vm.selectedViewID = viewB.id
        _ = vm.groupedSelected
        #expect(vm.groupedRecomputeCount > countAfterA)
    }

    @MainActor
    @Test("groupedSelected returns an empty array when no view is selected")
    func noSelectionReturnsEmpty() async throws {
        let (vm, _, _) = Self.makeViewModel(suiteName: "NoSelection")
        #expect(vm.selectedViewID == nil)
        #expect(vm.groupedSelected.isEmpty)
    }

    @MainActor
    @Test("cached grouping structurally matches a fresh groupedByOrgAndRepo call")
    func cacheReturnsEquivalentValue() async throws {
        let (vm, mock, _) = Self.makeViewModel(suiteName: "Equivalence")
        let pr1 = TestPullRequestFactory.make(id: "PR_1", repository: Repository(nameWithOwner: "acme/web"), headRefName: "a")
        let pr2 = TestPullRequestFactory.make(id: "PR_2", repository: Repository(nameWithOwner: "acme/web"), headRefName: "b")
        let pr3 = TestPullRequestFactory.make(id: "PR_3", repository: Repository(nameWithOwner: "acme/api"), headRefName: "c")
        _ = await Self.addViewAndRefresh(vm, title: "A", prs: [pr1, pr2, pr3], mock: mock)
        let cached = vm.groupedSelected
        let fresh = vm.groupedByOrgAndRepo(vm.selectedViewState.pullRequests)
        // OrgGroup isn't Equatable — compare the structural shape that the
        // UI renders against: org names, repo names per org, and the set of
        // PR IDs per repo.
        func shape(_ groups: [PRGrouping.OrgGroup]) -> [(String, [(String, [String])])] {
            groups.map { org in
                (org.org, org.repos.map { repo in
                    (repo.repo, repo.stacks.flatMap { [$0.root.id] + $0.children.map(\.id) })
                })
            }
        }
        let cachedShape = shape(cached)
        let freshShape = shape(fresh)
        #expect(cachedShape.count == freshShape.count)
        for (a, b) in zip(cachedShape, freshShape) {
            #expect(a.0 == b.0)
            #expect(a.1.map(\.0) == b.1.map(\.0))
            for (ra, rb) in zip(a.1, b.1) {
                #expect(ra.1 == rb.1)
            }
        }
    }
}
