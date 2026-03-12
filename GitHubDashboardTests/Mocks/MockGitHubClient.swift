import Foundation
@testable import GitHubDashboard

final class MockGitHubClient: GitHubClientProtocol, @unchecked Sendable {
    var pullRequestsToReturn: [PullRequest] = []
    var viewerLoginToReturn: String = "testuser"
    var errorToThrow: Error?
    var fetchPullRequestsCallCount = 0
    var receivedQueries: [String] = []

    func fetchPullRequests(query: String) async throws -> [PullRequest] {
        fetchPullRequestsCallCount += 1
        receivedQueries.append(query)
        if let error = errorToThrow { throw error }
        return pullRequestsToReturn
    }

    func fetchViewerLogin() async throws -> String {
        if let error = errorToThrow { throw error }
        return viewerLoginToReturn
    }
}
