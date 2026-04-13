import Foundation
@testable import PullRequestPilot

final class MockGitHubClient: GitHubClientProtocol, @unchecked Sendable {
    var pullRequestsToReturn: [PullRequest] = []
    var nextCursorToReturn: String?
    var viewerLoginToReturn: String = "testuser"
    var viewerAvatarURLToReturn: URL?
    var timelineEventsToReturn: [TimelineEvent] = []
    var timelineNextCursorToReturn: String?
    var reviewersToReturn: [Reviewer] = []
    var checksNextCursorToReturn: String?
    var checksPageToReturn: ChecksPage?
    var errorToThrow: Error?
    var fetchViewerError: Error?
    var fetchPullRequestsCallCount = 0
    var fetchTimelineCallCount = 0
    var fetchChecksCallCount = 0
    var receivedQueries: [String] = []
    var receivedCursors: [String?] = []

    func fetchPullRequests(query: String, cursor: String?) async throws -> PullRequestPage {
        fetchPullRequestsCallCount += 1
        receivedQueries.append(query)
        receivedCursors.append(cursor)
        if let error = errorToThrow { throw error }
        return PullRequestPage(pullRequests: pullRequestsToReturn, nextCursor: nextCursorToReturn, skippedNodeCount: 0)
    }

    var checkRunsToReturn: [CheckRun] = []

    func fetchTimeline(nodeID: String, cursor: String?, eventPageOffset: Int, checksPageOffset: Int) async throws -> TimelinePage {
        fetchTimelineCallCount += 1
        if let error = errorToThrow { throw error }
        return TimelinePage(events: timelineEventsToReturn, checkRuns: checkRunsToReturn, reviewers: reviewersToReturn, nextCursor: timelineNextCursorToReturn, checksNextCursor: checksNextCursorToReturn)
    }

    func fetchChecks(nodeID: String, cursor: String, checksPageOffset: Int) async throws -> ChecksPage {
        fetchChecksCallCount += 1
        if let error = errorToThrow { throw error }
        if let page = checksPageToReturn { return page }
        return ChecksPage(checkRuns: [], nextCursor: nil)
    }

    func fetchViewer() async throws -> (login: String, avatarURL: URL?) {
        if let error = fetchViewerError { throw error }
        if let error = errorToThrow { throw error }
        return (login: viewerLoginToReturn, avatarURL: viewerAvatarURLToReturn)
    }
}
