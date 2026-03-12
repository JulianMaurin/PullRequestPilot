import Testing
import Foundation
@testable import GitHubDashboard

@MainActor
@Suite("ReviewQueueViewModel")
struct ReviewQueueViewModelTests {
    let mockClient = MockGitHubClient()

    @Test("loads pull requests on refresh")
    func loadsPullRequests() async {
        let pr = makePullRequest(number: 1, title: "Fix bug")
        mockClient.pullRequestsToReturn = [pr]

        let viewModel = ReviewQueueViewModel(gitHubClient: mockClient)
        await viewModel.refresh()

        #expect(viewModel.pullRequests.count == 1)
        #expect(viewModel.pullRequests.first?.title == "Fix bug")
        #expect(viewModel.error == nil)
        #expect(!viewModel.isLoading)
    }

    @Test("surfaces error message on failure")
    func handlesError() async {
        mockClient.errorToThrow = GitHubClientError.unauthorized

        let viewModel = ReviewQueueViewModel(gitHubClient: mockClient)
        await viewModel.refresh()

        #expect(viewModel.pullRequests.isEmpty)
        #expect(viewModel.error != nil)
    }

    @Test("isEmpty is true when no PRs and not loading")
    func isEmpty() async {
        mockClient.pullRequestsToReturn = []

        let viewModel = ReviewQueueViewModel(gitHubClient: mockClient)
        await viewModel.refresh()

        #expect(viewModel.isEmpty)
    }

    // MARK: - Helpers

    private func makePullRequest(number: Int, title: String) -> PullRequest {
        PullRequest(
            id: "PR_\(number)",
            number: number,
            title: title,
            url: URL(string: "https://github.com/owner/repo/pull/\(number)")!,
            repository: Repository(nameWithOwner: "owner/repo"),
            author: Author(login: "author", avatarURL: nil),
            createdAt: Date().addingTimeInterval(-3600),
            updatedAt: Date(),
            additions: 10,
            deletions: 5,
            isDraft: false,
            reviewDecision: .reviewRequired,
            labels: []
        )
    }
}
