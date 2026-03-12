import Foundation
@testable import GitHubDashboard

final class MockGitHubClient: GitHubClientProtocol, @unchecked Sendable {
    var pullRequestsToReturn: [PullRequest] = []
    var viewerLoginToReturn: String = "testuser"
    var errorToThrow: Error?
    var fetchReviewRequestsCallCount = 0

    func fetchReviewRequests() async throws -> [PullRequest] {
        fetchReviewRequestsCallCount += 1
        if let error = errorToThrow { throw error }
        return pullRequestsToReturn
    }

    func fetchViewerLogin() async throws -> String {
        if let error = errorToThrow { throw error }
        return viewerLoginToReturn
    }
}
