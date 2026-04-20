import Foundation
import os

/// Sendable wrapper around a `Task` dictionary. Lets `@MainActor` types cancel
/// their in-flight work from `deinit`, which runs outside actor isolation in
/// Swift 6.
final class TaskMap: Sendable {
    private let storage = OSAllocatedUnfairLock<[UUID: Task<Void, Never>]>(initialState: [:])

    func task(for key: UUID) -> Task<Void, Never>? {
        storage.withLock { $0[key] }
    }

    func insert(_ task: Task<Void, Never>, for key: UUID) {
        storage.withLock { $0[key] = task }
    }

    func remove(_ key: UUID) {
        storage.withLock { _ = $0.removeValue(forKey: key) }
    }

    func cancelAndRemove(_ key: UUID) {
        storage.withLock { map in
            map.removeValue(forKey: key)?.cancel()
        }
    }

    func cancelAll() {
        storage.withLock { map in
            map.values.forEach { $0.cancel() }
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

    func resetState(for viewID: UUID) {
        states[viewID] = ViewState()
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
        if let pending = pendingRefreshes.task(for: view.id) {
            _ = await pending.value
            return
        }
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(for: view)
        }
        pendingRefreshes.insert(task, for: view.id)
        _ = await task.value
        pendingRefreshes.remove(view.id)
    }

    func loadMore(for view: DashboardView) async {
        if let pending = pendingLoadMores.task(for: view.id) {
            _ = await pending.value
            return
        }
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.performLoadMore(for: view)
        }
        pendingLoadMores.insert(task, for: view.id)
        _ = await task.value
        pendingLoadMores.remove(view.id)
    }

    // MARK: - Private

    private func performRefresh(for view: DashboardView) async {
        ensureState(for: view.id)
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

            states[view.id]?.pullRequests = filteredPRs
            states[view.id]?.seenIDs = seenIDs
            states[view.id]?.nextCursor = page.nextCursor
            states[view.id]?.rawFetchedCount = uniquePRs.count
            states[view.id]?.reachedLimit = uniquePRs.count >= Constants.App.maxPullRequests
            states[view.id]?.skippedPRCount = page.skippedNodeCount
            logger.info("Fetched \(uniquePRs.count, privacy: .public) PR(s) for '\(view.title, privacy: .public)'")
            onFetched?(FetchOutcome(viewID: view.id, pullRequests: filteredPRs))
        } catch is CancellationError {
            states[view.id]?.isLoading = false
            return
        } catch {
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
            let newPRs = page.pullRequests.filter { states[view.id]?.seenIDs.insert($0.id).inserted == true }
            let filteredNewPRs = await filter(newPRs, view)

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
