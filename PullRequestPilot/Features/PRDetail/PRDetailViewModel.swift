import Foundation
import os

@MainActor
@Observable
final class PRDetailViewModel {
    private(set) var selectedPR: PullRequest?
    private(set) var timelineEvents: [TimelineEvent] = []
    private(set) var checkRuns: [CheckRun] = []
    private(set) var reviewers: [Reviewer] = []
    /// A first load: the pane has nothing to show yet.
    private(set) var isLoading = false
    /// A reload behind content already on screen.
    private(set) var isRefreshing = false
    private(set) var error: String?
    private(set) var isNetworkError = false

    // Section state lives here, not in the view: switching between the side
    // and bottom layouts rebuilds the view.
    var isReviewersExpanded = true
    var isChecksExpanded = false
    /// The row kept in view across those rebuilds.
    var scrollAnchor: String?

    private let gitHubClient: GitHubClientProtocol
    private let reporter: EventReporter
    /// Lock-backed so deinit can cancel without hopping to MainActor.
    private let fetchTaskStorage = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    private var fetchTask: Task<Void, Never>? {
        get { fetchTaskStorage.withLock { $0 } }
        set { fetchTaskStorage.withLock { $0 = newValue } }
    }

    init(gitHubClient: GitHubClientProtocol, reporter: EventReporter = .noop) {
        self.gitHubClient = gitHubClient
        self.reporter = reporter
    }

    deinit {
        fetchTaskStorage.withLock { task in
            task?.cancel()
            task = nil
        }
    }

    /// Selecting the open pull request again closes it.
    func selectPR(_ pr: PullRequest) {
        guard pr.id != selectedPR?.id else {
            deselect()
            return
        }
        selectedPR = pr
        isReviewersExpanded = true
        isChecksExpanded = false
        scrollAnchor = nil
        load(keepingContent: false)
    }

    func retry() {
        guard selectedPR != nil else { return }
        load(keepingContent: false)
    }

    /// Reloads checks, reviewers and activity, keeping the current ones on
    /// screen until the new ones arrive.
    func refresh() {
        guard selectedPR != nil else { return }
        load(keepingContent: true)
    }

    /// The list fetched a newer copy of the open pull request. A change means
    /// its checks, reviews or activity moved, so the detail reloads too.
    func updateSelectedPR(_ pr: PullRequest) {
        guard pr.id == selectedPR?.id, pr != selectedPR else { return }
        selectedPR = pr
        load(keepingContent: true)
    }

    /// Returns once the load started by the latest selection, retry or
    /// refresh has finished.
    func waitForCurrentLoad() async {
        await fetchTask?.value
    }

    func deselect() {
        selectedPR = nil
        fetchTask?.cancel()
        timelineEvents = []
        checkRuns = []
        reviewers = []
        error = nil
        isNetworkError = false
        isLoading = false
        isRefreshing = false
    }

    // MARK: - Private

    private struct Detail {
        let events: [TimelineEvent]
        let checkRuns: [CheckRun]
        let reviewers: [Reviewer]
    }

    /// State flips happen here, before the task starts: a task cancelled
    /// before its first line runs must leave nothing behind.
    private func load(keepingContent: Bool) {
        guard let pr = selectedPR else { return }
        fetchTask?.cancel()
        let showsCurrentContent = keepingContent && !isLoading && error == nil
        if showsCurrentContent {
            isRefreshing = true
        } else {
            isLoading = true
            isRefreshing = false
            error = nil
            isNetworkError = false
            timelineEvents = []
            checkRuns = []
            reviewers = []
        }
        fetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let detail = try await fetchDetail(of: pr)
                guard !Task.isCancelled else { return }
                timelineEvents = detail.events
                checkRuns = detail.checkRuns
                reviewers = detail.reviewers
            } catch is CancellationError {
                // URLError.cancelled arrives as CancellationError without this
                // task being cancelled; only then does it still own the flags.
                guard !Task.isCancelled else { return }
            } catch {
                guard !Task.isCancelled else { return }
                // A failed reload keeps what's on screen; the toast says why.
                if !showsCurrentContent {
                    self.isNetworkError = error.isNetworkError
                    self.error = error.asAppError.errorDescription
                }
                reporter.post(.error(error.asAppError))
            }
            isLoading = false
            isRefreshing = false
        }
    }

    private func fetchDetail(of pr: PullRequest) async throws -> Detail {
        var allEvents: [TimelineEvent] = []
        var allCheckRuns: [CheckRun] = []
        var fetchedReviewers: [Reviewer] = []
        var cursor: String?
        var checksCursor: String?
        var eventPageOffset = 0
        var checksPageOffset = 0
        var previousTimelineCursor: String?
        var timelinePages = 0
        let maxPages = 20
        repeat {
            // Coalesced requests don't propagate cancellation, so each
            // iteration must check explicitly or an abandoned fetch
            // paginates to maxPages in the background.
            try Task.checkCancellation()
            timelinePages += 1
            let page = try await gitHubClient.fetchTimeline(
                nodeID: pr.id,
                cursor: cursor,
                eventPageOffset: eventPageOffset,
                checksPageOffset: checksPageOffset
            )
            allEvents.append(contentsOf: page.events)
            eventPageOffset += page.eventNodeCount
            allCheckRuns.append(contentsOf: page.checkRuns)
            checksPageOffset += page.checkRuns.count
            // Always capture the latest checksNextCursor — the first page may not have one
            if let pageChecksCursor = page.checksNextCursor {
                checksCursor = pageChecksCursor
            }
            fetchedReviewers.append(contentsOf: page.reviewers)
            // Guard against duplicate cursors that would cause an infinite loop
            if page.nextCursor != nil, page.nextCursor == previousTimelineCursor { break }
            previousTimelineCursor = page.nextCursor
            cursor = page.nextCursor
        } while cursor != nil && timelinePages < maxPages

        // Paginate remaining check runs
        var previousChecksCursor: String?
        var checksPages = 0
        while let nextChecksCursor = checksCursor, checksPages < maxPages {
            try Task.checkCancellation()
            checksPages += 1
            // Guard against duplicate cursors that would cause an infinite loop
            guard nextChecksCursor != previousChecksCursor else { break }
            previousChecksCursor = nextChecksCursor
            let checksPage = try await gitHubClient.fetchChecks(
                nodeID: pr.id,
                cursor: nextChecksCursor,
                checksPageOffset: checksPageOffset
            )
            allCheckRuns.append(contentsOf: checksPage.checkRuns)
            checksPageOffset += checksPage.checkRuns.count
            checksCursor = checksPage.nextCursor
        }

        // Deduplicate reviewers across pages, keeping last occurrence (latest state)
        var seenReviewerIDs = Set<String>()
        let deduplicatedReviewers = fetchedReviewers.reversed().filter { seenReviewerIDs.insert($0.id).inserted }.reversed()

        return Detail(
            events: allEvents,
            // Dedupe check runs across pages by `(name, workflowRunID)`,
            // keeping the latest attempt per group.
            checkRuns: allCheckRuns.deduplicatedLatest(),
            reviewers: Array(deduplicatedReviewers)
        )
    }
}
