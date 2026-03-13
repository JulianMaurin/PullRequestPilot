import Foundation
@testable import PullRequestPilot

final class MockGitHubClient: GitHubClientProtocol, @unchecked Sendable {
    var pullRequestsToReturn: [PullRequest] = []
    var viewerLoginToReturn: String = "testuser"
    var errorToThrow: Error?
    var fetchPullRequestsCallCount = 0
    var receivedQueries: [String] = []

    func fetchPullRequests(query: String, cursor: String?) async throws -> PullRequestPage {
        fetchPullRequestsCallCount += 1
        receivedQueries.append(query)
        if let error = errorToThrow { throw error }
        return PullRequestPage(pullRequests: pullRequestsToReturn, nextCursor: nil)
    }

    func fetchViewerLogin() async throws -> String {
        if let error = errorToThrow { throw error }
        return viewerLoginToReturn
    }
}
