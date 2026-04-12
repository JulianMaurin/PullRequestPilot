import Foundation

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
    private var fetchTask: Task<Void, Never>?

    init(gitHubClient: GitHubClientProtocol) {
        self.gitHubClient = gitHubClient
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

    private func deduplicateCheckRuns(_ runs: [CheckRun]) -> [CheckRun] {
        var bestByName: [String: CheckRun] = [:]
        var nameOrder: [String] = []
        for run in runs {
            if let existing = bestByName[run.name] {
                if run.conclusionPriority > existing.conclusionPriority {
                    bestByName[run.name] = run
                }
            } else {
                nameOrder.append(run.name)
                bestByName[run.name] = run
            }
        }
        return nameOrder.compactMap { bestByName[$0] }
    }

    private func fetchTimeline() {
        guard let pr = selectedPR else { return }
        fetchTask = Task {
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
                repeat {
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
                } while cursor != nil

                // Paginate remaining check runs
                var previousChecksCursor: String?
                while let nextChecksCursor = checksCursor {
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

                // Deduplicate check runs across pages by name, keeping the best conclusion
                let deduplicatedCheckRuns = deduplicateCheckRuns(allCheckRuns)

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
            }
            isLoading = false
        }
    }
}
