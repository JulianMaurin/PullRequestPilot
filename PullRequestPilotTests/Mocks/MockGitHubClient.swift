import Foundation
@testable import PullRequestPilot

final class MockGitHubClient: GitHubClientProtocol, @unchecked Sendable {
    var pullRequestsToReturn: [PullRequest] = []
    var nextCursorToReturn: String?
    var viewerLoginToReturn: String = "testuser"
    var viewerAvatarURLToReturn: URL?
    var timelineEventsToReturn: [TimelineEvent] = []
    var timelineNextCursorToReturn: String?
    var errorToThrow: Error?
    var fetchPullRequestsCallCount = 0
    var receivedQueries: [String] = []
    var receivedCursors: [String?] = []

    func fetchPullRequests(query: String, cursor: String?) async throws -> PullRequestPage {
        fetchPullRequestsCallCount += 1
        receivedQueries.append(query)
        receivedCursors.append(cursor)
        if let error = errorToThrow { throw error }
        return PullRequestPage(pullRequests: pullRequestsToReturn, nextCursor: nextCursorToReturn)
    }

    var checkRunsToReturn: [CheckRun] = []

    func fetchTimeline(nodeID: String, cursor: String?) async throws -> TimelinePage {
        if let error = errorToThrow { throw error }
        return TimelinePage(events: timelineEventsToReturn, checkRuns: checkRunsToReturn, nextCursor: timelineNextCursorToReturn, checksNextCursor: nil)
    }

    func fetchChecks(nodeID: String, cursor: String) async throws -> ChecksPage {
        if let error = errorToThrow { throw error }
        return ChecksPage(checkRuns: [], nextCursor: nil)
    }

    func fetchViewer() async throws -> (login: String, avatarURL: URL?) {
        if let error = errorToThrow { throw error }
        return (login: viewerLoginToReturn, avatarURL: viewerAvatarURLToReturn)
    }
}
