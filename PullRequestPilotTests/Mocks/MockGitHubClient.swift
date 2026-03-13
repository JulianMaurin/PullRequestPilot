import Foundation
@testable import PullRequestPilot

final class MockGitHubClient: GitHubClientProtocol, @unchecked Sendable {
    var pullRequestsToReturn: [PullRequest] = []
    var nextCursorToReturn: String?
    var viewerLoginToReturn: String = "testuser"
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

    func fetchViewerLogin() async throws -> String {
        if let error = errorToThrow { throw error }
        return viewerLoginToReturn
    }
}
