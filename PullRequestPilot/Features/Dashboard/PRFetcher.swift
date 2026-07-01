import Foundation
import os

/// Sendable wrapper around a `Task` dictionary. Lets `@MainActor` types cancel
/// their in-flight work from `deinit`, which runs outside actor isolation in
/// Swift 6.
final class TaskMap: Sendable {
    private struct Entry {
        let task: Task<Void, Never>
        let label: String?
    }

    private let storage = OSAllocatedUnfairLock<[UUID: Entry]>(initialState: [:])

    func task(for key: UUID) -> Task<Void, Never>? {
        storage.withLock { $0[key]?.task }
    }

    /// Returns the pending task only when its label matches. Joining is
    /// keyed on (view, query): a pending fetch for a different query is
    /// superseded input, and joining it would return the old query's results
    /// under the new query's name.
    func task(for key: UUID, label: String?) -> Task<Void, Never>? {
        storage.withLock { map in
            guard let entry = map[key], entry.label == label else { return nil }
            return entry.task
        }
    }

    func insert(_ task: Task<Void, Never>, for key: UUID, label: String? = nil) {
        storage.withLock { $0[key] = Entry(task: task, label: label) }
    }

    func remove(_ key: UUID) {
        storage.withLock { _ = $0.removeValue(forKey: key) }
    }

    /// Removes the entry only if it still holds `task`. Creators use this so
    /// finishing a superseded task never evicts a successor inserted for the
    /// same key after a reset.
    func removeIfIdentical(_ task: Task<Void, Never>, for key: UUID) {
        storage.withLock { map in
            if map[key]?.task == task {
                map.removeValue(forKey: key)
            }
        }
    }

    func cancelAndRemove(_ key: UUID) {
        storage.withLock { map in
            map.removeValue(forKey: key)?.task.cancel()
        }
    }

    func cancelAll() {
        storage.withLock { map in
            map.values.forEach { $0.task.cancel() }
            map.removeAll()
        }
    }
}

@MainActor
@Observable
final class PRFetcher {

    // MARK: - Types

    typealias PRFilter = @MainActor ([PullRequest], DashboardView) async -> [PullRequest]

    struct FetchOutcome {
        let viewID: UUID
        let pullRequests: [PullRequest]
    }

    // MARK: - Properties

    private(set) var states: [UUID: ViewState] = [:]

    /// Invoked once per successful full-page `refresh` with the post-filter PR
    /// list for that view. Owners use this to apply badge / notification logic.
    /// Not invoked for `loadMore` or for cancelled / failed fetches.
    var onFetched: ((FetchOutcome) -> Void)?

    private let gitHubClient: GitHubClientProtocol
    private let filter: PRFilter
    private let reporter: EventReporter
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PullRequestPilot", category: "PRFetcher")

    /// Coalesces concurrent `refresh(for:)` calls: a second caller for the
    /// same view joins the first task's completion instead of starting a
    /// parallel fetch. Backed by a lock so `deinit` can cancel everything
    /// without needing MainActor isolation.
    private let pendingRefreshes = TaskMap()
    private let pendingLoadMores = TaskMap()

    // MARK: - Init

    init(gitHubClient: GitHubClientProtocol, filter: @escaping PRFilter, reporter: EventReporter = .noop) {
        self.gitHubClient = gitHubClient
        self.filter = filter
        self.reporter = reporter
    }

    deinit {
        pendingRefreshes.cancelAll()
        pendingLoadMores.cancelAll()
    }

    // MARK: - State access

    func state(for viewID: UUID) -> ViewState {
        states[viewID] ?? ViewState()
    }

    func ensureState(for viewID: UUID) {
        if states[viewID] == nil {
            states[viewID] = ViewState()
        }
    }

    /// Cancels in-flight work as well as clearing the state: a reset marks the
    /// current query as superseded, so a fetch started for the old query must
    /// never be joined by — or commit into — the fresh state.
    func resetState(for viewID: UUID) {
        states[viewID] = ViewState()
        pendingRefreshes.cancelAndRemove(viewID)
        pendingLoadMores.cancelAndRemove(viewID)
    }

    func removeState(for viewID: UUID) {
        states.removeValue(forKey: viewID)
        pendingRefreshes.cancelAndRemove(viewID)
        pendingLoadMores.cancelAndRemove(viewID)
    }

    func cancelAll() {
        pendingRefreshes.cancelAll()
        pendingLoadMores.cancelAll()
    }

    func clearAll() {
        cancelAll()
        states = [:]
    }

    // MARK: - Public API

    func refresh(for view: DashboardView) async {
        if let pending = pendingRefreshes.task(for: view.id, label: view.query) {
            _ = await pending.value
            return
        }
        // A pending refresh under a different query can be inserted after
        // resetState by a caller still holding the pre-edit view snapshot
        // (e.g. a refreshAll child). Cancel it — its commit gates drop the
        // result — instead of letting the current query join it.
        pendingRefreshes.cancelAndRemove(view.id)
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(for: view)
        }
        pendingRefreshes.insert(task, for: view.id, label: view.query)
        _ = await task.value
        pendingRefreshes.removeIfIdentical(task, for: view.id)
    }

    func loadMore(for view: DashboardView) async {
        if let pending = pendingLoadMores.task(for: view.id, label: view.query) {
            _ = await pending.value
            return
        }
        pendingLoadMores.cancelAndRemove(view.id)
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.performLoadMore(for: view)
        }
        pendingLoadMores.insert(task, for: view.id, label: view.query)
        _ = await task.value
        pendingLoadMores.removeIfIdentical(task, for: view.id)
    }

    // MARK: - Private

    private func performRefresh(for view: DashboardView) async {
        ensureState(for: view.id)
        // A full refresh replaces the list and cursor, so any in-flight
        // pagination would append a stale-cursor page onto the new list.
        pendingLoadMores.cancelAndRemove(view.id)
        states[view.id]?.isLoading = true
        states[view.id]?.error = nil
        states[view.id]?.isNetworkError = false
        states[view.id]?.rateLimitRetryAfter = nil

        logger.info("Fetching PRs for '\(view.title, privacy: .public)'...")

        do {
            let page = try await gitHubClient.fetchPullRequests(query: view.query, cursor: nil)
            var seenIDs = Set<String>()
            let uniquePRs = page.pullRequests.filter { seenIDs.insert($0.id).inserted }
            let filteredPRs = await filter(uniquePRs, view)

            // Cancellation does not surface from the awaits above (the
            // client's coalescer resolves them normally), so a resetState
            // that landed mid-fetch is only visible here. A superseded task
            // must not touch the state at all: every canceller replaces or
            // removes it, and a successor refresh may already own its flags.
            guard !Task.isCancelled else { return }

            states[view.id]?.pullRequests = filteredPRs
            states[view.id]?.seenIDs = seenIDs
            states[view.id]?.nextCursor = page.nextCursor
            states[view.id]?.rawFetchedCount = uniquePRs.count
            states[view.id]?.reachedLimit = uniquePRs.count >= Constants.App.maxPullRequests
            states[view.id]?.skippedPRCount = page.skippedNodeCount
            logger.info("Fetched \(uniquePRs.count, privacy: .public) PR(s) for '\(view.title, privacy: .public)'")
            onFetched?(FetchOutcome(viewID: view.id, pullRequests: filteredPRs))
        } catch is CancellationError {
            // URLError.cancelled rethrows as CancellationError without this
            // task being cancelled (session-level); only then does this task
            // still own the state's loading flag.
            if !Task.isCancelled {
                states[view.id]?.isLoading = false
            }
            return
        } catch {
            // A superseded task must not write the old query's error into the
            // successor's fresh state, nor toast for a query that no longer
            // exists.
            guard !Task.isCancelled else { return }
            logger.error("Failed to fetch PRs for '\(view.title, privacy: .public)': \(error, privacy: .public)")
            states[view.id]?.isNetworkError = error.isNetworkError
            states[view.id]?.error = error.localizedDescription
            if let clientError = error as? GitHubClientError, case .rateLimited(let retryAfter) = clientError {
                states[view.id]?.rateLimitRetryAfter = retryAfter
            }
            reporter.post(.error(appError(from: error)))
        }

        states[view.id]?.isLoading = false
    }

    private func performLoadMore(for view: DashboardView) async {
        guard let state = states[view.id], state.canLoadMore else { return }

        states[view.id]?.isLoadingMore = true
        states[view.id]?.error = nil
        states[view.id]?.isNetworkError = false
        states[view.id]?.rateLimitRetryAfter = nil

        do {
            let page = try await gitHubClient.fetchPullRequests(query: view.query, cursor: state.nextCursor)

            // Drop the page if a reset or refresh superseded the pre-await
            // snapshot: appending would mix stale rows into the new list and
            // overwrite its cursor with the stale chain's. Checked before the
            // seenIDs insert below so a dropped page's IDs cannot suppress a
            // later legitimate fetch.
            guard !Task.isCancelled, states[view.id]?.nextCursor == state.nextCursor else {
                states[view.id]?.isLoadingMore = false
                return
            }

            let newPRs = page.pullRequests.filter { states[view.id]?.seenIDs.insert($0.id).inserted == true }
            let filteredNewPRs = await filter(newPRs, view)

            // The filter await is a second suspension point; re-check before
            // committing so a reset/refresh landing during it cannot slip a
            // stale page in. Unlike performRefresh, the flag write stays: a
            // refresh cancels this task without replacing the state, and
            // nothing else would clear isLoadingMore.
            guard !Task.isCancelled, states[view.id]?.nextCursor == state.nextCursor else {
                states[view.id]?.isLoadingMore = false
                return
            }

            states[view.id]?.pullRequests.append(contentsOf: filteredNewPRs)
            states[view.id]?.nextCursor = page.nextCursor
            let rawTotal = (states[view.id]?.rawFetchedCount ?? 0) + newPRs.count
            states[view.id]?.rawFetchedCount = rawTotal
            states[view.id]?.reachedLimit = rawTotal >= Constants.App.maxPullRequests
            logger.info("Loaded \(newPRs.count, privacy: .public) more PR(s) for '\(view.title, privacy: .public)' (total: \(rawTotal, privacy: .public))")
        } catch is CancellationError {
            states[view.id]?.isLoadingMore = false
            return
        } catch {
            // Superseded: clear only our own flag — the old query's error
            // must not surface for a query that no longer exists.
            guard !Task.isCancelled else {
                states[view.id]?.isLoadingMore = false
                return
            }
            logger.error("Failed to load more PRs for '\(view.title, privacy: .public)': \(error, privacy: .public)")
            states[view.id]?.isNetworkError = error.isNetworkError
            states[view.id]?.error = error.localizedDescription
            if let clientError = error as? GitHubClientError, case .rateLimited(let retryAfter) = clientError {
                states[view.id]?.rateLimitRetryAfter = retryAfter
            }
            reporter.post(.error(appError(from: error)))
        }

        states[view.id]?.isLoadingMore = false
    }
}
