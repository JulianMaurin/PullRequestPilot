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

    private static func page(ids: [String], cursor: String?) -> PullRequestPage {
        PullRequestPage(
            pullRequests: ids.map { TestPullRequestFactory.make(id: $0) },
            nextCursor: cursor,
            skippedNodeCount: 0
        )
    }

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

    /// Drains the gated client if a test misses an interleaving: parked
    /// continuations would otherwise never resume, the body's trailing awaits
    /// would never resolve, and the run would hang past its time limit
    /// instead of reporting the failed `releaseFetch` expectations. Cancelled
    /// on the success path before it fires (the sleep throws and the drain is
    /// skipped — the unobserved error is the point).
    private static func gateWatchdog(for client: GatedGitHubClient) -> Task<Void, any Error> {
        Task {
            try await Task.sleep(for: .seconds(20))
            await client.failAllPending()
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

    // MARK: - TaskMap

    @Test("removeIfIdentical removes only the exact task instance")
    func taskMapRemoveIfIdentical() {
        let map = TaskMap()
        let key = UUID()
        let first: Task<Void, Never> = Task {}
        let second: Task<Void, Never> = Task {}
        map.insert(first, for: key)
        map.removeIfIdentical(second, for: key)
        #expect(map.task(for: key) == first)
        map.removeIfIdentical(first, for: key)
        #expect(map.task(for: key) == nil)
    }

    // MARK: - query-edit supersession

    @MainActor
    @Test("resetState cancels the in-flight refresh so a new-query refresh fetches fresh", .timeLimit(.minutes(1)))
    func resetStateSupersedesInFlightRefresh() async throws {
        let client = GatedGitHubClient()
        let watchdog = Self.gateWatchdog(for: client)
        defer { watchdog.cancel() }
        let fetcher = PRFetcher(gitHubClient: client, filter: Self.identityFilter)
        let viewID = UUID()
        let oldView = DashboardView(id: viewID, title: "Test", query: "is:pr label:old")
        let newView = DashboardView(id: viewID, title: "Test", query: "is:pr label:new")

        async let oldRefresh: Void = fetcher.refresh(for: oldView)
        try await client.waitForFetch(query: oldView.query, cursor: nil)

        // Mirrors commitQueryEdit: reset, then refresh with the updated view.
        fetcher.resetState(for: viewID)
        async let newRefresh: Void = fetcher.refresh(for: newView)
        try await client.waitForFetch(query: newView.query, cursor: nil)

        // Release the new page and wait for its commit before releasing the
        // stale one: the old-query result then resolves strictly after the
        // new commit and must be dropped, not written over it.
        #expect(await client.releaseFetch(query: newView.query, cursor: nil, returning: Self.page(ids: ["PR_new"], cursor: "cursor-new")))
        try await Self.waitUntil { fetcher.states[viewID]?.pullRequests.map(\.id) == ["PR_new"] }
        #expect(await client.releaseFetch(query: oldView.query, cursor: nil, returning: Self.page(ids: ["PR_old"], cursor: "cursor-old")))
        _ = await newRefresh
        _ = await oldRefresh

        let state = try #require(fetcher.states[viewID])
        #expect(state.pullRequests.map(\.id) == ["PR_new"])
        #expect(state.nextCursor == "cursor-new")
        #expect(await client.fetchPullRequestsCallCount == 2)
    }

    // MARK: - refresh / loadMore interleave

    @MainActor
    @Test("a refresh started mid-loadMore supersedes the stale page", .timeLimit(.minutes(1)))
    func refreshSupersedesInFlightLoadMore() async throws {
        let client = GatedGitHubClient()
        let watchdog = Self.gateWatchdog(for: client)
        defer { watchdog.cancel() }
        let fetcher = PRFetcher(gitHubClient: client, filter: Self.identityFilter)
        let view = Self.makeView()

        async let initialRefresh: Void = fetcher.refresh(for: view)
        try await client.waitForFetch(query: view.query, cursor: nil)
        #expect(await client.releaseFetch(query: view.query, cursor: nil, returning: Self.page(ids: ["PR_1"], cursor: "cursor-1")))
        _ = await initialRefresh

        async let staleLoadMore: Void = fetcher.loadMore(for: view)
        try await client.waitForFetch(query: view.query, cursor: "cursor-1")

        async let secondRefresh: Void = fetcher.refresh(for: view)
        try await client.waitForFetch(query: view.query, cursor: nil)
        #expect(await client.releaseFetch(query: view.query, cursor: nil, returning: Self.page(ids: ["PR_2"], cursor: "cursor-2")))
        _ = await secondRefresh

        #expect(await client.releaseFetch(query: view.query, cursor: "cursor-1", returning: Self.page(ids: ["PR_stale"], cursor: "cursor-stale")))
        _ = await staleLoadMore

        let state = try #require(fetcher.states[view.id])
        #expect(state.pullRequests.map(\.id) == ["PR_2"])
        #expect(state.nextCursor == "cursor-2")
        #expect(state.isLoadingMore == false)
    }

    @MainActor
    @Test("a loadMore that raced an in-flight refresh drops its stale-cursor page", .timeLimit(.minutes(1)))
    func loadMoreDuringRefreshDropsStalePage() async throws {
        let client = GatedGitHubClient()
        let watchdog = Self.gateWatchdog(for: client)
        defer { watchdog.cancel() }
        let fetcher = PRFetcher(gitHubClient: client, filter: Self.identityFilter)
        let view = Self.makeView()

        async let initialRefresh: Void = fetcher.refresh(for: view)
        try await client.waitForFetch(query: view.query, cursor: nil)
        #expect(await client.releaseFetch(query: view.query, cursor: nil, returning: Self.page(ids: ["PR_1"], cursor: "cursor-1")))
        _ = await initialRefresh

        // Refresh first — its start-of-fetch loadMore cancellation misses a
        // loadMore that begins afterwards, so only the commit-time cursor
        // check can reject the stale page.
        async let secondRefresh: Void = fetcher.refresh(for: view)
        try await client.waitForFetch(query: view.query, cursor: nil)
        async let staleLoadMore: Void = fetcher.loadMore(for: view)
        try await client.waitForFetch(query: view.query, cursor: "cursor-1")

        #expect(await client.releaseFetch(query: view.query, cursor: nil, returning: Self.page(ids: ["PR_2"], cursor: "cursor-2")))
        _ = await secondRefresh

        #expect(await client.releaseFetch(query: view.query, cursor: "cursor-1", returning: Self.page(ids: ["PR_stale"], cursor: "cursor-stale")))
        _ = await staleLoadMore

        let state = try #require(fetcher.states[view.id])
        #expect(state.pullRequests.map(\.id) == ["PR_2"])
        #expect(state.nextCursor == "cursor-2")
        #expect(state.seenIDs.contains("PR_stale") == false)
        #expect(state.isLoadingMore == false)
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

// MARK: - GatedGitHubClient

/// Gates every `fetchPullRequests` call on a continuation so tests control the
/// exact interleaving of concurrent fetches. Actor-backed for the same reason
/// as `MockGitHubClient`: parallel tasks read and release fetches concurrently.
private actor GatedGitHubClient: GitHubClientProtocol {

    private struct PendingFetch {
        let query: String
        let cursor: String?
        let continuation: CheckedContinuation<PullRequestPage, any Error>
    }

    private var pendingFetches: [PendingFetch] = []
    private var isDraining = false
    private(set) var fetchPullRequestsCallCount = 0

    func fetchPullRequests(query: String, cursor: String?) async throws -> PullRequestPage {
        fetchPullRequestsCallCount += 1
        if isDraining { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            pendingFetches.append(PendingFetch(query: query, cursor: cursor, continuation: continuation))
        }
    }

    /// Resumes every parked fetch — and, via the latch, every future one —
    /// with `CancellationError`. Watchdog escape hatch: a missed interleaving
    /// otherwise parks a fetch forever, the test body's trailing awaits never
    /// resolve, and the whole run hangs instead of reporting the failed
    /// `releaseFetch` expectation. PRFetcher treats the error as a dropped
    /// fetch, so draining only unblocks — it cannot fake a success.
    func failAllPending() {
        isDraining = true
        for pending in pendingFetches {
            pending.continuation.resume(throwing: CancellationError())
        }
        pendingFetches.removeAll()
    }

    /// Polls until a fetch matching `query`/`cursor` is suspended awaiting
    /// release. Returns at the deadline without failing — the caller's
    /// `releaseFetch` expectation then reports the missing fetch, and the
    /// test's watchdog drains the gates so the trailing awaits resolve.
    func waitForFetch(query: String, cursor: String?) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !pendingFetches.contains(where: { $0.query == query && $0.cursor == cursor }) {
            if ContinuousClock.now >= deadline { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Resumes the pending fetch matching `query`/`cursor` with `page`.
    /// Returns `false` when no such fetch is suspended, so tests can
    /// `#expect` the release found its target.
    func releaseFetch(query: String, cursor: String?, returning page: PullRequestPage) -> Bool {
        guard let index = pendingFetches.firstIndex(where: { $0.query == query && $0.cursor == cursor }) else {
            return false
        }
        pendingFetches.remove(at: index).continuation.resume(returning: page)
        return true
    }

    func fetchTimeline(nodeID: String, cursor: String?, eventPageOffset: Int, checksPageOffset: Int) async throws -> TimelinePage {
        TimelinePage(events: [], checkRuns: [], reviewers: [], nextCursor: nil, checksNextCursor: nil)
    }

    func fetchChecks(nodeID: String, cursor: String, checksPageOffset: Int) async throws -> ChecksPage {
        ChecksPage(checkRuns: [], nextCursor: nil)
    }

    func fetchViewer() async throws -> (login: String, avatarURL: URL?) {
        (login: "testuser", avatarURL: nil)
    }

    func validateToken(_ token: String) async throws -> (login: String, avatarURL: URL?) {
        (login: "testuser", avatarURL: nil)
    }

    func setDraft(pullRequestID: String, isDraft: Bool) async throws {}
}
