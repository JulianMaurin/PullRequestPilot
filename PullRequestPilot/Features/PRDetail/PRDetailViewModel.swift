import Foundation
import os

@MainActor
@Observable
final class PRDetailViewModel {
    private(set) var selectedPR: PullRequest?
    private(set) var timelineEvents: [TimelineEvent] = []
    private(set) var checkRuns: [CheckRun] = []
    private(set) var reviewers: [Reviewer] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var isNetworkError = false

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

    func selectPR(_ pr: PullRequest) {
        guard pr.id != selectedPR?.id else {
            deselect()
            return
        }
        selectedPR = pr
        fetchTask?.cancel()
        fetchTimeline()
    }

    func retry() {
        guard selectedPR != nil else { return }
        fetchTask?.cancel()
        fetchTimeline()
    }

    func updateSelectedPR(_ pr: PullRequest) {
        guard pr.id == selectedPR?.id else { return }
        selectedPR = pr
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
    }

    // MARK: - Private

    private func fetchTimeline() {
        guard let pr = selectedPR else { return }
        fetchTask = Task { [weak self] in
            guard let self else { return }
            isLoading = true
            error = nil
            isNetworkError = false
            timelineEvents = []
            checkRuns = []
            reviewers = []
            do {
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
                    eventPageOffset += page.events.count
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

                // Dedupe check runs across pages by `(name, workflowRunID)`,
                // keeping the latest attempt per group.
                let deduplicatedCheckRuns = allCheckRuns.deduplicatedLatest()

                // Deduplicate reviewers across pages, keeping last occurrence (latest state)
                var seenReviewerIDs = Set<String>()
                let deduplicatedReviewers = fetchedReviewers.reversed().filter { seenReviewerIDs.insert($0.id).inserted }.reversed()

                guard !Task.isCancelled else { return }
                timelineEvents = allEvents
                checkRuns = deduplicatedCheckRuns
                reviewers = Array(deduplicatedReviewers)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.isNetworkError = error.isNetworkError
                self.error = error.localizedDescription
                reporter.post(.error(appError(from: error)))
            }
            isLoading = false
        }
    }
}

// MARK: - Error mapping helper

@MainActor
func appError(from error: Error) -> AppError {
    if let clientError = error as? GitHubClientError {
        return clientError.asAppError
    }
    if let appError = error as? AppError {
        return appError
    }
    if let urlError = error as? URLError {
        return .network(underlying: urlError.localizedDescription)
    }
    return .network(underlying: error.localizedDescription)
}
