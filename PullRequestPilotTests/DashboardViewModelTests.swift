import Testing
import Foundation
@testable import PullRequestPilot

@MainActor
@Suite("DashboardViewModel")
struct DashboardViewModelTests {
    let mockClient = MockGitHubClient()
    let localRepoService = LocalRepositoryService()

    private func makeViewModel(suiteName: String = "DashboardViewModelTests") -> DashboardViewModel {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService)
        let testView = DashboardView(id: UUID(), title: "Test View", query: "is:pr is:open")
        viewModel.addView(testView)
        return viewModel
    }

    @Test("loads pull requests for a view on refresh")
    func loadsPullRequests() async {
        let pr = makePullRequest(number: 1, title: "Fix bug")
        mockClient.pullRequestsToReturn = [pr]

        let viewModel = makeViewModel(suiteName: "LoadsPRs")
        let viewID = viewModel.views.first!.id
        await viewModel.refresh(viewID: viewID)

        let state = viewModel.viewStates[viewID]!
        #expect(state.pullRequests.count == 1)
        #expect(state.pullRequests.first?.title == "Fix bug")
        #expect(state.error == nil)
        #expect(!state.isLoading)
    }

    @Test("surfaces error message on failure")
    func handlesError() async {
        mockClient.errorToThrow = GitHubClientError.unauthorized

        let viewModel = makeViewModel(suiteName: "HandlesError")
        let viewID = viewModel.views.first!.id
        await viewModel.refresh(viewID: viewID)

        let state = viewModel.viewStates[viewID]!
        #expect(state.pullRequests.isEmpty)
        #expect(state.error != nil)
    }

    @Test("isEmpty is true when no PRs and not loading")
    func isEmpty() async {
        mockClient.pullRequestsToReturn = []

        let viewModel = makeViewModel(suiteName: "IsEmpty")
        let viewID = viewModel.views.first!.id
        await viewModel.refresh(viewID: viewID)

        #expect(viewModel.viewStates[viewID]!.isEmpty)
    }

    @Test("passes the view query to the client")
    func passesQueryToClient() async {
        let viewModel = makeViewModel(suiteName: "PassesQuery")
        let view = viewModel.views.first!
        await viewModel.refresh(viewID: view.id)

        #expect(mockClient.receivedQueries.last == view.query)
    }

    @Test("add and delete views")
    func addAndDeleteViews() {
        let viewModel = makeViewModel(suiteName: "AddDeleteViews")
        let initialCount = viewModel.views.count

        let newView = DashboardView(id: UUID(), title: "My PRs", query: "is:pr author:@me")
        viewModel.addView(newView)
        #expect(viewModel.views.count == initialCount + 1)

        viewModel.deleteView(id: newView.id)
        #expect(viewModel.views.count == initialCount)
    }

    @Test("hideReviewed filters out PRs with active reviews but keeps dismissed")
    func hideReviewedFiltering() async {
        let approvedPR = makePullRequest(number: 1, title: "Approved", reviews: [
            UserReview(login: "testuser", state: .approved)
        ])
        let dismissedPR = makePullRequest(number: 2, title: "Dismissed", reviews: [
            UserReview(login: "testuser", state: .dismissed)
        ])
        let unreviewedPR = makePullRequest(number: 3, title: "Unreviewed", reviews: [])
        let otherReviewPR = makePullRequest(number: 4, title: "Other reviewed", reviews: [
            UserReview(login: "someone-else", state: .approved)
        ])
        mockClient.pullRequestsToReturn = [approvedPR, dismissedPR, unreviewedPR, otherReviewPR]

        let defaults = UserDefaults(suiteName: "HideReviewedTests")!
        defaults.removePersistentDomain(forName: "HideReviewedTests")
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService)
        let testView = DashboardView(id: UUID(), title: "Review", query: "is:pr", hideReviewed: true)
        viewModel.addView(testView)
        let viewID = testView.id

        #expect(viewModel.views.first(where: { $0.id == viewID })?.hideReviewed == true)
        await viewModel.refresh(viewID: viewID)

        let state = viewModel.viewStates[viewID]!
        let titles = state.pullRequests.map(\.title)
        #expect(titles.contains("Dismissed"))
        #expect(titles.contains("Unreviewed"))
        #expect(titles.contains("Other reviewed"))
        #expect(!titles.contains("Approved"))
    }

    // MARK: - Network Error State

    @Test("refresh sets isNetworkError on network failure")
    func refreshSetsNetworkError() async {
        mockClient.errorToThrow = GitHubClientError.networkError(URLError(.notConnectedToInternet))

        let viewModel = makeViewModel(suiteName: "NetworkError")
        let viewID = viewModel.views.first!.id
        await viewModel.refresh(viewID: viewID)

        let state = viewModel.viewStates[viewID]!
        #expect(state.isNetworkError)
        #expect(state.error != nil)
    }

    @Test("refresh clears isNetworkError on success after previous network error")
    func refreshClearsNetworkError() async {
        mockClient.errorToThrow = GitHubClientError.networkError(URLError(.notConnectedToInternet))

        let viewModel = makeViewModel(suiteName: "ClearsNetworkError")
        let viewID = viewModel.views.first!.id
        await viewModel.refresh(viewID: viewID)
        #expect(viewModel.viewStates[viewID]!.isNetworkError)

        mockClient.errorToThrow = nil
        mockClient.pullRequestsToReturn = [makePullRequest(number: 1, title: "OK")]
        await viewModel.refresh(viewID: viewID)

        let state = viewModel.viewStates[viewID]!
        #expect(!state.isNetworkError)
        #expect(state.error == nil)
    }

    @Test("isNetworkError is false for non-network errors")
    func nonNetworkErrorDoesNotSetFlag() async {
        mockClient.errorToThrow = GitHubClientError.unauthorized

        let viewModel = makeViewModel(suiteName: "NonNetworkError")
        let viewID = viewModel.views.first!.id
        await viewModel.refresh(viewID: viewID)

        let state = viewModel.viewStates[viewID]!
        #expect(!state.isNetworkError)
        #expect(state.error != nil)
    }

    // MARK: - showingSettings

    @Test("showingSettings defaults to false")
    func showingSettingsDefault() {
        let viewModel = makeViewModel(suiteName: "SettingsDefault")
        #expect(!viewModel.showingSettings)
    }

    @Test("showingSettings can be toggled")
    func showingSettingsToggle() {
        let viewModel = makeViewModel(suiteName: "SettingsToggle")
        viewModel.showingSettings = true
        #expect(viewModel.showingSettings)
        viewModel.showingSettings = false
        #expect(!viewModel.showingSettings)
    }

    // MARK: - Helpers

    private func makePullRequest(number: Int, title: String, reviews: [UserReview] = []) -> PullRequest {
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
            state: .open,
            isDraft: false,
            checkStatus: .success,
            reviewDecision: .reviewRequired,
            totalThreads: 0,
            unresolvedThreads: 0,
            labels: [],
            baseRefName: "main",
            headRefName: "feature-\(number)",
            headCommitSha: nil,
            lastActivity: nil,
            latestReviews: reviews
        )
    }
}
