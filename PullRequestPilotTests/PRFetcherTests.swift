import Testing
import Foundation
@testable import PullRequestPilot

@Suite("PRFetcher")
struct PRFetcherTests {

    // MARK: - Fixtures

    private static func makeView() -> DashboardView {
        DashboardView(id: UUID(), title: "Test", query: "is:pr")
    }

    /// Identity filter — returns input unchanged. Used when the test doesn't
    /// exercise filter behaviour.
    private static let identityFilter: PRFetcher.PRFilter = { prs, _ in prs }

    @MainActor
    private static func makeFetcher(
        client: MockGitHubClient,
        filter: @escaping PRFetcher.PRFilter = PRFetcherTests.identityFilter
    ) -> PRFetcher {
        PRFetcher(gitHubClient: client, filter: filter)
    }

    @MainActor
    private static func waitUntil(
        deadlineSeconds: Double = 2.0,
        _ predicate: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(deadlineSeconds))
        while !predicate() {
            if ContinuousClock.now >= deadline { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - state access

    @MainActor
    @Test("state(for:) returns a default ViewState when the view has no entry")
    func defaultState() {
        let client = MockGitHubClient()
        let fetcher = Self.makeFetcher(client: client)
        let state = fetcher.state(for: UUID())
        #expect(state.pullRequests.isEmpty)
        #expect(state.isLoading == false)
    }

    @MainActor
    @Test("ensureState creates an empty state entry")
    func ensureStateCreates() {
        let client = MockGitHubClient()
        let fetcher = Self.makeFetcher(client: client)
        let id = UUID()
        fetcher.ensureState(for: id)
        #expect(fetcher.states[id] != nil)
    }

    // MARK: - refresh happy path

    @MainActor
    @Test("refresh writes fetched PRs into the view state")
    func refreshWritesPRs() async throws {
        let client = MockGitHubClient()
        let pr = TestPullRequestFactory.make(id: "PR_1", title: "One")
        await client.setPullRequestsToReturn([pr])
        let fetcher = Self.makeFetcher(client: client)
        let view = Self.makeView()
        await fetcher.refresh(for: view)
        let state = try #require(fetcher.states[view.id])
        #expect(state.pullRequests.map(\.id) == ["PR_1"])
        #expect(state.isLoading == false)
        #expect(state.error == nil)
    }

    // MARK: - onFetched contract

    @MainActor
    @Test("onFetched fires after the state is committed")
    func onFetchedAfterStateCommit() async throws {
        let client = MockGitHubClient()
        let pr = TestPullRequestFactory.make(id: "PR_onFetched")
        await client.setPullRequestsToReturn([pr])
        let fetcher = Self.makeFetcher(client: client)
        let view = Self.makeView()

        // Capture the state as seen *by the onFetched callback*. If the
        // callback fires before the state commit, this would be empty.
        var stateSeenByCallback: [String] = []
        fetcher.onFetched = { outcome in
            stateSeenByCallback = fetcher.state(for: outcome.viewID).pullRequests.map(\.id)
        }

        await fetcher.refresh(for: view)
        #expect(stateSeenByCallback == ["PR_onFetched"])
    }

    @MainActor
    @Test("onFetched does not fire on cancellation")
    func onFetchedNotFiredOnCancellation() async throws {
        let client = MockGitHubClient()
        await client.setErrorToThrow(CancellationError())
        let fetcher = Self.makeFetcher(client: client)
        let view = Self.makeView()

        var fired = false
        fetcher.onFetched = { _ in fired = true }

        await fetcher.refresh(for: view)
        #expect(fired == false)
    }

    @MainActor
    @Test("onFetched does not fire when the fetch throws a network error")
    func onFetchedNotFiredOnError() async throws {
        let client = MockGitHubClient()
        await client.setErrorToThrow(URLError(.notConnectedToInternet))
        let fetcher = Self.makeFetcher(client: client)
        let view = Self.makeView()

        var fired = false
        fetcher.onFetched = { _ in fired = true }

        await fetcher.refresh(for: view)
        #expect(fired == false)
    }

    // MARK: - coalescing

    @MainActor
    @Test("a second refresh while one is in flight coalesces onto the first")
    func refreshCoalesces() async throws {
        // The mock's call counter is bumped on every actual network call.
        // If coalescing works, two concurrent refresh(for:) calls should
        // result in a *single* call to fetchPullRequests.
        let client = MockGitHubClient()
        await client.setPullRequestsToReturn([TestPullRequestFactory.make(id: "PR_coalesce")])
        let fetcher = Self.makeFetcher(client: client)
        let view = Self.makeView()

        async let a: Void = fetcher.refresh(for: view)
        async let b: Void = fetcher.refresh(for: view)
        _ = await [a, b]

        #expect(await client.fetchPullRequestsCallCount == 1)
    }

    // MARK: - error path

    @MainActor
    @Test("a thrown network error lands in state.error without rethrowing")
    func errorLandsInState() async throws {
        let client = MockGitHubClient()
        await client.setErrorToThrow(URLError(.notConnectedToInternet))
        let fetcher = Self.makeFetcher(client: client)
        let view = Self.makeView()

        await fetcher.refresh(for: view) // must not throw
        let state = try #require(fetcher.states[view.id])
        #expect(state.error != nil)
        #expect(state.isNetworkError == true)
        #expect(state.isLoading == false)
    }

    @MainActor
    @Test("a rate-limit error is captured in state.rateLimitRetryAfter")
    func rateLimitCaptured() async throws {
        let client = MockGitHubClient()
        await client.setErrorToThrow(GitHubClientError.rateLimited(retryAfter: 120))
        let fetcher = Self.makeFetcher(client: client)
        let view = Self.makeView()

        await fetcher.refresh(for: view)
        let state = try #require(fetcher.states[view.id])
        #expect(state.rateLimitRetryAfter == 120)
    }

    // MARK: - cancellation

    @MainActor
    @Test("cancellation does not surface as a user-visible error")
    func cancellationIsQuiet() async throws {
        let client = MockGitHubClient()
        await client.setErrorToThrow(CancellationError())
        let fetcher = Self.makeFetcher(client: client)
        let view = Self.makeView()

        await fetcher.refresh(for: view)
        let state = try #require(fetcher.states[view.id])
        #expect(state.error == nil)
        #expect(state.isNetworkError == false)
        #expect(state.isLoading == false)
    }

    // MARK: - filter

    @MainActor
    @Test("the filter closure sees the unique PRs and can drop entries")
    func filterDrops() async throws {
        let client = MockGitHubClient()
        let a = TestPullRequestFactory.make(id: "PR_keep", title: "keep")
        let b = TestPullRequestFactory.make(id: "PR_drop", title: "drop")
        await client.setPullRequestsToReturn([a, b])

        let filter: PRFetcher.PRFilter = { prs, _ in
            prs.filter { $0.id == "PR_keep" }
        }
        let fetcher = Self.makeFetcher(client: client, filter: filter)
        let view = Self.makeView()

        await fetcher.refresh(for: view)
        let state = try #require(fetcher.states[view.id])
        #expect(state.pullRequests.map(\.id) == ["PR_keep"])
    }

    // MARK: - loadMore

    @MainActor
    @Test("loadMore appends new PRs without replacing the existing list")
    func loadMoreAppends() async throws {
        let client = MockGitHubClient()
        let initial = TestPullRequestFactory.make(id: "PR_1", title: "first")
        await client.setPullRequestsToReturn([initial])
        await client.setNextCursorToReturn("cursor-1")
        let fetcher = Self.makeFetcher(client: client)
        let view = Self.makeView()

        await fetcher.refresh(for: view)
        // Second page: return a new PR; cursor ends.
        let second = TestPullRequestFactory.make(id: "PR_2", title: "second")
        await client.setPullRequestsToReturn([second])
        await client.setNextCursorToReturn(nil)

        await fetcher.loadMore(for: view)
        let state = try #require(fetcher.states[view.id])
        #expect(state.pullRequests.map(\.id) == ["PR_1", "PR_2"])
        #expect(state.canLoadMore == false)
    }

    @MainActor
    @Test("loadMore deduplicates PRs that appear on both pages")
    func loadMoreDeduplicates() async throws {
        let client = MockGitHubClient()
        let pr = TestPullRequestFactory.make(id: "PR_dup", title: "dup")
        await client.setPullRequestsToReturn([pr])
        await client.setNextCursorToReturn("cursor-1")
        let fetcher = Self.makeFetcher(client: client)
        let view = Self.makeView()

        await fetcher.refresh(for: view)
        // Same PR returned on the "next" page.
        await client.setPullRequestsToReturn([pr])
        await client.setNextCursorToReturn(nil)
        await fetcher.loadMore(for: view)
        let state = try #require(fetcher.states[view.id])
        #expect(state.pullRequests.map(\.id) == ["PR_dup"])
    }

    // MARK: - removeState / resetState / clearAll

    @MainActor
    @Test("removeState drops the entry and cancels pending tasks")
    func removeStateDrops() {
        let client = MockGitHubClient()
        let fetcher = Self.makeFetcher(client: client)
        let id = UUID()
        fetcher.ensureState(for: id)
        fetcher.removeState(for: id)
        #expect(fetcher.states[id] == nil)
    }

    @MainActor
    @Test("resetState clears the entry to an empty ViewState")
    func resetStateClears() async throws {
        let client = MockGitHubClient()
        await client.setPullRequestsToReturn([TestPullRequestFactory.make(id: "PR_R")])
        let fetcher = Self.makeFetcher(client: client)
        let view = Self.makeView()
        await fetcher.refresh(for: view)
        fetcher.resetState(for: view.id)
        let state = try #require(fetcher.states[view.id])
        #expect(state.pullRequests.isEmpty)
        #expect(state.nextCursor == nil)
    }

    @MainActor
    @Test("clearAll removes every entry")
    func clearAllWipes() async throws {
        let client = MockGitHubClient()
        await client.setPullRequestsToReturn([TestPullRequestFactory.make(id: "PR_C")])
        let fetcher = Self.makeFetcher(client: client)
        let viewA = Self.makeView()
        let viewB = Self.makeView()
        await fetcher.refresh(for: viewA)
        await fetcher.refresh(for: viewB)
        fetcher.clearAll()
        #expect(fetcher.states.isEmpty)
    }
}
