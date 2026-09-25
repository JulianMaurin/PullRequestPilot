import Testing
import Foundation
@testable import PullRequestPilot

@Suite("PRFetcher")
struct PRFetcherTests {

    // MARK: - Fixtures

    private static func makeView() -> ViewDefinition {
        ViewDefinition(id: UUID(), title: "Test", query: "is:pr")
    }

    /// Identity filter — returns input unchanged. Used when the test doesn't
    /// exercise filter behaviour.
    private static let identityFilter: PRFetcher.PRFilter = { prs, _ in prs }

    private static func page(ids: [String], cursor: String?) throws -> PullRequestPage {
        PullRequestPage(
            pullRequests: try ids.map { try TestPullRequestFactory.make(id: $0) },
            nextCursor: cursor
        )
    }

    @MainActor
    private static func makeFetcher(
        client: MockGitHubClient,
        filter: @escaping PRFetcher.PRFilter = PRFetcherTests.identityFilter,
        reporter: EventReporter = .noop
    ) -> PRFetcher {
        PRFetcher(gitHubClient: client, filter: filter, reporter: reporter)
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

    // MARK: - What the list shows about itself

    @MainActor
    @Test("a failed page is marked as a load-more failure; the next refresh clears it")
    func loadMoreFailureIsMarked() async throws {
        let client = MockGitHubClient()
        let fetcher = Self.makeFetcher(client: client)
        let view = Self.makeView()
        await client.setPullRequestsToReturn([try TestPullRequestFactory.make(id: "PR_1")])
        await client.setNextCursorToReturn("cursor-1")
        await fetcher.refresh(for: view)

        await client.setErrorToThrow(GitHubClientError.serverError(statusCode: 502))
        await fetcher.loadMore(for: view)
        #expect(fetcher.state(for: view.id).loadMoreFailed)
        #expect(fetcher.state(for: view.id).error != nil)

        await fetcher.refresh(for: view)
        #expect(!fetcher.state(for: view.id).loadMoreFailed)
    }

    @MainActor
    @Test("a failed refresh is not a load-more failure")
    func refreshFailureIsNotLoadMore() async throws {
        let client = MockGitHubClient()
        let fetcher = Self.makeFetcher(client: client)
        let view = Self.makeView()
        await client.setErrorToThrow(GitHubClientError.serverError(statusCode: 502))

        await fetcher.refresh(for: view)

        #expect(fetcher.state(for: view.id).error != nil)
        #expect(!fetcher.state(for: view.id).loadMoreFailed)
    }

    @MainActor
    @Test("pull requests the filter removes are counted, across pages")
    func filteredOutCount() async throws {
        let client = MockGitHubClient()
        let fetcher = Self.makeFetcher(client: client, filter: { prs, _ in prs.filter { $0.id.hasSuffix("keep") } })
        let view = Self.makeView()
        await client.setPullRequestsToReturn([try TestPullRequestFactory.make(id: "PR_1_keep"), try TestPullRequestFactory.make(id: "PR_2_drop")])
        await client.setNextCursorToReturn("cursor-1")
        await fetcher.refresh(for: view)
        #expect(fetcher.state(for: view.id).filteredOutCount == 1)

        await client.setPullRequestsToReturn([try TestPullRequestFactory.make(id: "PR_3_drop"), try TestPullRequestFactory.make(id: "PR_4_drop")])
        await client.setNextCursorToReturn(nil)
        await fetcher.loadMore(for: view)
        #expect(fetcher.state(for: view.id).filteredOutCount == 3)
        #expect(fetcher.state(for: view.id).pullRequests.map(\.id) == ["PR_1_keep"])
    }

    @MainActor
    @Test("the list says it's truncated only when GitHub has more past the cap")
    func truncation() async throws {
        let client = MockGitHubClient()
        let fetcher = Self.makeFetcher(client: client)
        let view = Self.makeView()
        let full = try (0..<Constants.App.maxPullRequests).map { try TestPullRequestFactory.make(id: "PR_\($0)") }
        await client.setPullRequestsToReturn(full)

        await client.setNextCursorToReturn(nil)
        await fetcher.refresh(for: view)
        #expect(!fetcher.state(for: view.id).isTruncated)

        await client.setNextCursorToReturn("more")
        await fetcher.refresh(for: view)
        #expect(fetcher.state(for: view.id).isTruncated)
    }

    // MARK: - Reporting

    @MainActor
    @Test("a failed refresh toasts its error; the next success resolves a transient 401")
    func refreshFailureToastsAndSuccessResolves() async throws {
        let client = MockGitHubClient()
        let recorder = EventRecorder()
        let fetcher = Self.makeFetcher(client: client, reporter: recorder.reporter())
        let view = Self.makeView()

        await client.setErrorToThrow(GitHubClientError.unauthorized)
        await fetcher.refresh(for: view)
        #expect(recorder.unresolvedErrors == [.unauthorized])

        await client.setErrorToThrow(nil)
        await fetcher.refresh(for: view)
        #expect(recorder.unresolvedErrors.isEmpty)
    }

    @MainActor
    @Test("without a token, a refresh says so in the view and posts no toast")
    func missingTokenStaysInTheView() async throws {
        let client = MockGitHubClient()
        let recorder = EventRecorder()
        let fetcher = Self.makeFetcher(client: client, reporter: recorder.reporter())
        let view = Self.makeView()
        await client.setErrorToThrow(GitHubClientError.missingToken)

        await fetcher.refresh(for: view)

        #expect(fetcher.state(for: view.id).error == AppError.missingToken.errorDescription)
        #expect(!fetcher.state(for: view.id).isLoading)
        #expect(recorder.events.isEmpty)
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
        let pr = try TestPullRequestFactory.make(id: "PR_1", title: "One")
        await client.setPullRequestsToReturn([pr])
        let fetcher = Self.makeFetcher(client: client)
        let view = Self.makeView()
        await fetcher.refresh(for: view)
        let state = try #require(fetcher.states[view.id])
        #expect(state.pullRequests.map(\.id) == ["PR_1"])
        #expect(state.isLoading == false)
        #expect(state.error == nil)
    }

    // MARK: - refresh depth

    @MainActor
    @Test("a refresh re-fetches as deep as the user has paged, keeping page-2 rows")
    func refreshKeepsLoadedDepth() async throws {
        let client = MockGitHubClient()
        let firstPage = try (1...50).map { try TestPullRequestFactory.make(id: "PR_\($0)") }
        let secondPage = try (51...100).map { try TestPullRequestFactory.make(id: "PR_\($0)") }
        let fetcher = Self.makeFetcher(client: client)
        let view = Self.makeView()

        await client.setPullRequestsToReturn(firstPage)
        await client.setNextCursorToReturn("cursor-1")
        await fetcher.refresh(for: view)
        await client.setPullRequestsToReturn(secondPage)
        await client.setNextCursorToReturn("cursor-2")
        await fetcher.loadMore(for: view)
        #expect(fetcher.state(for: view.id).pullRequests.count == 100)

        await client.setPullRequestsToReturn(firstPage + secondPage)
        await fetcher.refresh(for: view)

        #expect(await client.receivedPageSizes == [50, 50, 100])
        #expect(fetcher.state(for: view.id).pullRequests.count == 100)
    }

    @MainActor
    @Test("load-more after a deep refresh only asks for what fits under the cap")
    func loadMoreFillsUpToCap() async throws {
        let client = MockGitHubClient()
        let fetcher = Self.makeFetcher(client: client)
        let view = Self.makeView()

        try await client.setPullRequestsToReturn((1...50).map { try TestPullRequestFactory.make(id: "PR_\($0)") })
        await client.setNextCursorToReturn("cursor-1")
        await fetcher.refresh(for: view)
        try await client.setPullRequestsToReturn((51...60).map { try TestPullRequestFactory.make(id: "PR_\($0)") })
        await client.setNextCursorToReturn(nil)
        await fetcher.loadMore(for: view)

        // More matches arrived since: the refresh fetches the 60 already
        // loaded and reports another page.
        try await client.setPullRequestsToReturn((1...60).map { try TestPullRequestFactory.make(id: "PR_\($0)") })
        await client.setNextCursorToReturn("cursor-2")
        await fetcher.refresh(for: view)
        try await client.setPullRequestsToReturn((61...100).map { try TestPullRequestFactory.make(id: "PR_\($0)") })
        await fetcher.loadMore(for: view)

        #expect(await client.receivedPageSizes == [50, 50, 60, 40])
        #expect(fetcher.state(for: view.id).reachedLimit)
    }

    // MARK: - hidden results notice

    @Test("withheld results explain themselves with GitHub's reason")
    func hiddenResultsNoticeForWithheldResults() {
        let page = PullRequestPage(
            pullRequests: [],
            nextCursor: nil,
            withheldResultCount: 3,
            partialErrorMessages: ["Resource protected by organization SAML enforcement."]
        )
        #expect(PRFetcher.hiddenResultsNotice(for: page) == "GitHub withheld 3 results. Resource protected by organization SAML enforcement.")
    }

    @Test("undecodable pull requests are reported with where to look")
    func hiddenResultsNoticeForUndecodablePullRequests() {
        let page = PullRequestPage(pullRequests: [], nextCursor: nil, undecodablePullRequestCount: 1)
        #expect(PRFetcher.hiddenResultsNotice(for: page) == "1 pull request couldn't be read and is hidden; Help › Export Logs… has the details.")
    }

    @Test("a complete page has no notice, and non-PR matches aren't hidden results")
    func noHiddenResultsNotice() {
        let page = PullRequestPage(pullRequests: [], nextCursor: nil, nonPullRequestCount: 4)
        #expect(PRFetcher.hiddenResultsNotice(for: page) == nil)
    }

    // MARK: - onFetched contract

    @MainActor
    @Test("onFetched fires after the state is committed")
    func onFetchedAfterStateCommit() async throws {
        let client = MockGitHubClient()
        let pr = try TestPullRequestFactory.make(id: "PR_onFetched")
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
        await client.setPullRequestsToReturn([try TestPullRequestFactory.make(id: "PR_coalesce")])
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
        let a = try TestPullRequestFactory.make(id: "PR_keep", title: "keep")
        let b = try TestPullRequestFactory.make(id: "PR_drop", title: "drop")
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
        let initial = try TestPullRequestFactory.make(id: "PR_1", title: "first")
        await client.setPullRequestsToReturn([initial])
        await client.setNextCursorToReturn("cursor-1")
        let fetcher = Self.makeFetcher(client: client)
        let view = Self.makeView()

        await fetcher.refresh(for: view)
        // Second page: return a new PR; cursor ends.
        let second = try TestPullRequestFactory.make(id: "PR_2", title: "second")
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
        let pr = try TestPullRequestFactory.make(id: "PR_dup", title: "dup")
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
        #expect(map.task(for: key, label: nil) == first)
        map.removeIfIdentical(first, for: key)
        #expect(map.task(for: key, label: nil) == nil)
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
        let oldView = ViewDefinition(id: viewID, title: "Test", query: "is:pr label:old")
        let newView = ViewDefinition(id: viewID, title: "Test", query: "is:pr label:new")

        async let oldRefresh: Void = fetcher.refresh(for: oldView)
        try await client.waitForFetch(query: oldView.query, cursor: nil)

        // Mirrors commitQueryEdit: reset, then refresh with the updated view.
        fetcher.resetState(for: viewID)
        async let newRefresh: Void = fetcher.refresh(for: newView)
        try await client.waitForFetch(query: newView.query, cursor: nil)

        // Release the new page and wait for its commit before releasing the
        // stale one: the old-query result then resolves strictly after the
        // new commit and must be dropped, not written over it.
        let pageNew = try Self.page(ids: ["PR_new"], cursor: "cursor-new")
        #expect(await client.releaseFetch(query: newView.query, cursor: nil, returning: pageNew))
        try await TestWait.until { fetcher.states[viewID]?.pullRequests.map(\.id) == ["PR_new"] }
        let pageOld = try Self.page(ids: ["PR_old"], cursor: "cursor-old")
        #expect(await client.releaseFetch(query: oldView.query, cursor: nil, returning: pageOld))
        _ = await newRefresh
        _ = await oldRefresh

        let state = try #require(fetcher.states[viewID])
        #expect(state.pullRequests.map(\.id) == ["PR_new"])
        #expect(state.nextCursor == "cursor-new")
        #expect(await client.fetchPullRequestsCallCount == 2)
    }

    @MainActor
    @Test("a refresh under a new query supersedes an in-flight one instead of joining it", .timeLimit(.minutes(1)))
    func newQueryRefreshSupersedesWithoutReset() async throws {
        let client = GatedGitHubClient()
        let watchdog = Self.gateWatchdog(for: client)
        defer { watchdog.cancel() }
        let fetcher = PRFetcher(gitHubClient: client, filter: Self.identityFilter)
        let viewID = UUID()
        let oldView = ViewDefinition(id: viewID, title: "Test", query: "is:pr label:old")
        let newView = ViewDefinition(id: viewID, title: "Test", query: "is:pr label:new")

        async let oldRefresh: Void = fetcher.refresh(for: oldView)
        try await client.waitForFetch(query: oldView.query, cursor: nil)
        // No resetState: a caller holding the pre-edit snapshot started the
        // old refresh, and the new query must not join it.
        async let newRefresh: Void = fetcher.refresh(for: newView)
        try await client.waitForFetch(query: newView.query, cursor: nil)

        // The stale result lands first and must be dropped.
        let pageOld = try Self.page(ids: ["PR_old"], cursor: "cursor-old")
        #expect(await client.releaseFetch(query: oldView.query, cursor: nil, returning: pageOld))
        _ = await oldRefresh
        #expect(fetcher.states[viewID]?.pullRequests.isEmpty == true)

        let pageNew = try Self.page(ids: ["PR_new"], cursor: "cursor-new")
        #expect(await client.releaseFetch(query: newView.query, cursor: nil, returning: pageNew))
        _ = await newRefresh

        let state = try #require(fetcher.states[viewID])
        #expect(state.pullRequests.map(\.id) == ["PR_new"])
        #expect(state.nextCursor == "cursor-new")
        #expect(state.isLoading == false)
    }

    @MainActor
    @Test("a superseded refresh that fails posts nothing", .timeLimit(.minutes(1)))
    func supersededFailureDoesNotToast() async throws {
        let client = GatedGitHubClient()
        let watchdog = Self.gateWatchdog(for: client)
        defer { watchdog.cancel() }
        let recorder = EventRecorder()
        let fetcher = PRFetcher(gitHubClient: client, filter: Self.identityFilter, reporter: recorder.reporter())
        let viewID = UUID()
        let oldView = ViewDefinition(id: viewID, title: "Test", query: "is:pr label:old")
        let newView = ViewDefinition(id: viewID, title: "Test", query: "is:pr label:new")

        async let oldRefresh: Void = fetcher.refresh(for: oldView)
        try await client.waitForFetch(query: oldView.query, cursor: nil)
        fetcher.resetState(for: viewID)
        async let newRefresh: Void = fetcher.refresh(for: newView)
        try await client.waitForFetch(query: newView.query, cursor: nil)

        #expect(await client.failFetch(query: oldView.query, cursor: nil, with: GitHubClientError.serverError(statusCode: 502)))
        _ = await oldRefresh
        let pageNew = try Self.page(ids: ["PR_new"], cursor: nil)
        #expect(await client.releaseFetch(query: newView.query, cursor: nil, returning: pageNew))
        _ = await newRefresh

        #expect(recorder.events.isEmpty)
        #expect(fetcher.states[viewID]?.error == nil)
    }

    @MainActor
    @Test("a failed load-more toasts its error")
    func loadMoreFailureToasts() async throws {
        let client = MockGitHubClient()
        let recorder = EventRecorder()
        let fetcher = Self.makeFetcher(client: client, reporter: recorder.reporter())
        let view = Self.makeView()
        await client.setPullRequestsToReturn([try TestPullRequestFactory.make(id: "PR_1")])
        await client.setNextCursorToReturn("cursor-1")
        await fetcher.refresh(for: view)

        await client.setErrorToThrow(GitHubClientError.serverError(statusCode: 503))
        await fetcher.loadMore(for: view)

        #expect(recorder.unresolvedErrors == [.serverError(statusCode: 503)])
        #expect(fetcher.states[view.id]?.pullRequests.map(\.id) == ["PR_1"])
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
        let page1 = try Self.page(ids: ["PR_1"], cursor: "cursor-1")
        #expect(await client.releaseFetch(query: view.query, cursor: nil, returning: page1))
        _ = await initialRefresh

        async let staleLoadMore: Void = fetcher.loadMore(for: view)
        try await client.waitForFetch(query: view.query, cursor: "cursor-1")

        async let secondRefresh: Void = fetcher.refresh(for: view)
        try await client.waitForFetch(query: view.query, cursor: nil)
        let page2 = try Self.page(ids: ["PR_2"], cursor: "cursor-2")
        #expect(await client.releaseFetch(query: view.query, cursor: nil, returning: page2))
        _ = await secondRefresh

        let pageStale = try Self.page(ids: ["PR_stale"], cursor: "cursor-stale")
        #expect(await client.releaseFetch(query: view.query, cursor: "cursor-1", returning: pageStale))
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
        let page1 = try Self.page(ids: ["PR_1"], cursor: "cursor-1")
        #expect(await client.releaseFetch(query: view.query, cursor: nil, returning: page1))
        _ = await initialRefresh

        // Refresh first — its start-of-fetch loadMore cancellation misses a
        // loadMore that begins afterwards, so only the commit-time cursor
        // check can reject the stale page.
        async let secondRefresh: Void = fetcher.refresh(for: view)
        try await client.waitForFetch(query: view.query, cursor: nil)
        async let staleLoadMore: Void = fetcher.loadMore(for: view)
        try await client.waitForFetch(query: view.query, cursor: "cursor-1")

        let page2 = try Self.page(ids: ["PR_2"], cursor: "cursor-2")
        #expect(await client.releaseFetch(query: view.query, cursor: nil, returning: page2))
        _ = await secondRefresh

        let pageStale = try Self.page(ids: ["PR_stale"], cursor: "cursor-stale")
        #expect(await client.releaseFetch(query: view.query, cursor: "cursor-1", returning: pageStale))
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
        await client.setPullRequestsToReturn([try TestPullRequestFactory.make(id: "PR_R")])
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
        await client.setPullRequestsToReturn([try TestPullRequestFactory.make(id: "PR_C")])
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

    func fetchPullRequests(query: String, cursor: String?, pageSize: Int) async throws -> PullRequestPage {
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

    /// Resumes the pending fetch matching `query`/`cursor` by throwing `error`.
    func failFetch(query: String, cursor: String?, with error: any Error) -> Bool {
        guard let index = pendingFetches.firstIndex(where: { $0.query == query && $0.cursor == cursor }) else {
            return false
        }
        pendingFetches.remove(at: index).continuation.resume(throwing: error)
        return true
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

    func validateToken(_ token: String) async throws -> TokenValidation {
        TokenValidation(login: "testuser", avatarURL: nil)
    }

    func setDraft(pullRequestID: String, isDraft: Bool) async throws {}
}
