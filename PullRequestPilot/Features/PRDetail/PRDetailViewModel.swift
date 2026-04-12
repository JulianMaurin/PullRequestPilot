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
                repeat {
                    let page = try await gitHubClient.fetchTimeline(nodeID: pr.id, cursor: cursor)
                    allEvents.append(contentsOf: page.events)
                    allCheckRuns.append(contentsOf: page.checkRuns)
                    if checksCursor == nil {
                        checksCursor = page.checksNextCursor
                    }
                    fetchedReviewers.append(contentsOf: page.reviewers)
                    cursor = page.nextCursor
                } while cursor != nil

                // Paginate remaining check runs
                while let nextChecksCursor = checksCursor {
                    let checksPage = try await gitHubClient.fetchChecks(nodeID: pr.id, cursor: nextChecksCursor)
                    allCheckRuns.append(contentsOf: checksPage.checkRuns)
                    checksCursor = checksPage.nextCursor
                }

                // Deduplicate reviewers across pages, keeping last occurrence (latest state)
                var seenReviewerIDs = Set<String>()
                let deduplicatedReviewers = fetchedReviewers.reversed().filter { seenReviewerIDs.insert($0.id).inserted }.reversed()

                guard !Task.isCancelled else { return }
                timelineEvents = allEvents
                checkRuns = allCheckRuns
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
