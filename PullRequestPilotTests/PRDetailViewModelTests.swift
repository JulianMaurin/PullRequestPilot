import Testing
import Foundation
@testable import PullRequestPilot

@MainActor
@Suite("PRDetailViewModel")
struct PRDetailViewModelTests {

    private func makeViewModel(client: MockGitHubClient = MockGitHubClient()) -> (PRDetailViewModel, MockGitHubClient) {
        let vm = PRDetailViewModel(gitHubClient: client)
        return (vm, client)
    }

    private func makePR(id: String = "PR_1") -> PullRequest {
        TestPullRequestFactory.make(id: id)
    }

    private func makeTimelineEvent(id: String = "1", kind: TimelineEventKind = .comment) -> TimelineEvent {
        TimelineEvent(
            id: id,
            kind: kind,
            actor: Author(login: "alice", avatarURL: nil),
            timestamp: Date(),
            body: nil
        )
    }

    /// Yield to let the Task start, then poll until the view model finishes loading.
    private func waitForLoad(_ vm: PRDetailViewModel, timeout: Duration = .milliseconds(500)) async throws {
        // Yield to let the fire-and-forget Task created by selectPR/retry begin.
        await Task.yield()
        let deadline = ContinuousClock.now + timeout
        while vm.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Selection

    @Test("selectPR sets selectedPR")
    func selectSetsSelectedPR() async throws {
        let (vm, _) = makeViewModel()
        let pr = makePR()
        vm.selectPR(pr)
        #expect(vm.selectedPR?.id == pr.id)
    }

    @Test("selectPR same PR twice deselects")
    func selectSamePRDeselects() async throws {
        let (vm, _) = makeViewModel()
        let pr = makePR()
        vm.selectPR(pr)
        vm.selectPR(pr)
        #expect(vm.selectedPR == nil)
    }

    @Test("deselect clears all state")
    func deselectClearsState() async throws {
        let client = MockGitHubClient()
        client.timelineEventsToReturn = [makeTimelineEvent()]
        let (vm, _) = makeViewModel(client: client)

        let pr = makePR()
        vm.selectPR(pr)
        try await waitForLoad(vm)

        vm.deselect()
        #expect(vm.selectedPR == nil)
        #expect(vm.timelineEvents.isEmpty)
        #expect(vm.error == nil)
        #expect(vm.isLoading == false)
    }

    // MARK: - Timeline Fetching

    @Test("selectPR fetches timeline events")
    func selectFetchesTimeline() async throws {
        let client = MockGitHubClient()
        let events = [
            makeTimelineEvent(id: "1", kind: .comment),
            makeTimelineEvent(id: "2", kind: .merged),
        ]
        client.timelineEventsToReturn = events
        let (vm, _) = makeViewModel(client: client)

        vm.selectPR(makePR())
        try await waitForLoad(vm)

        #expect(vm.timelineEvents.count == 2)
        #expect(vm.isLoading == false)
    }

    @Test("selectPR handles fetch error")
    func selectHandlesError() async throws {
        let client = MockGitHubClient()
        client.errorToThrow = GitHubClientError.networkError(URLError(.notConnectedToInternet))
        let (vm, _) = makeViewModel(client: client)

        vm.selectPR(makePR())
        try await waitForLoad(vm)

        #expect(vm.error != nil)
        #expect(vm.timelineEvents.isEmpty)
        #expect(vm.isLoading == false)
    }

    @Test("selectPR with empty timeline shows empty state")
    func selectEmptyTimeline() async throws {
        let client = MockGitHubClient()
        client.timelineEventsToReturn = []
        let (vm, _) = makeViewModel(client: client)

        vm.selectPR(makePR())
        try await waitForLoad(vm)

        #expect(vm.timelineEvents.isEmpty)
        #expect(vm.error == nil)
        #expect(vm.isLoading == false)
    }

    @Test("selecting different PR cancels previous fetch")
    func selectDifferentPRCancelsPrevious() async throws {
        let client = MockGitHubClient()
        client.timelineEventsToReturn = [makeTimelineEvent()]
        let (vm, _) = makeViewModel(client: client)

        vm.selectPR(makePR(id: "PR_1"))
        vm.selectPR(makePR(id: "PR_2"))
        try await waitForLoad(vm)

        #expect(vm.selectedPR?.id == "PR_2")
    }

    // MARK: - Network Error State

    @Test("selectPR sets isNetworkError on network failure")
    func selectSetsNetworkError() async throws {
        let client = MockGitHubClient()
        client.errorToThrow = GitHubClientError.networkError(URLError(.notConnectedToInternet))
        let (vm, _) = makeViewModel(client: client)

        vm.selectPR(makePR())
        try await waitForLoad(vm)

        #expect(vm.isNetworkError)
        #expect(vm.error != nil)
    }

    @Test("selectPR does not set isNetworkError for non-network errors")
    func selectDoesNotSetNetworkErrorForOtherErrors() async throws {
        let client = MockGitHubClient()
        client.errorToThrow = GitHubClientError.unauthorized
        let (vm, _) = makeViewModel(client: client)

        vm.selectPR(makePR())
        try await waitForLoad(vm)

        #expect(!vm.isNetworkError)
        #expect(vm.error != nil)
    }

    @Test("deselect clears isNetworkError")
    func deselectClearsNetworkError() async throws {
        let client = MockGitHubClient()
        client.errorToThrow = GitHubClientError.networkError(URLError(.timedOut))
        let (vm, _) = makeViewModel(client: client)

        vm.selectPR(makePR())
        try await waitForLoad(vm)
        #expect(vm.isNetworkError)

        vm.deselect()
        #expect(!vm.isNetworkError)
    }

    // MARK: - Reviewers

    @Test("selectPR populates reviewers from timeline")
    func selectPopulatesReviewers() async throws {
        let client = MockGitHubClient()
        let reviewers = [
            Reviewer(id: "r1", displayName: "alice", avatarURL: nil, isTeam: false, state: .approved),
            Reviewer(id: "r2", displayName: "bob", avatarURL: nil, isTeam: false, state: .pending),
        ]
        client.reviewersToReturn = reviewers
        let (vm, _) = makeViewModel(client: client)

        vm.selectPR(makePR())
        try await waitForLoad(vm)

        #expect(vm.reviewers.count == 2)
        #expect(vm.reviewers[0].displayName == "alice")
        #expect(vm.reviewers[0].state == .approved)
        #expect(vm.reviewers[1].displayName == "bob")
        #expect(vm.reviewers[1].state == .pending)
    }

    // MARK: - Check Run Pagination

    @Test("selectPR paginates check runs when checksNextCursor is set")
    func selectPaginatesCheckRuns() async throws {
        let client = MockGitHubClient()
        let initialChecks = [
            CheckRun(id: "c1", name: "lint", status: .completed, conclusion: .success, detailsURL: nil, isRequired: false),
        ]
        let paginatedChecks = [
            CheckRun(id: "c2", name: "build", status: .completed, conclusion: .success, detailsURL: nil, isRequired: true),
            CheckRun(id: "c3", name: "test", status: .completed, conclusion: .failure, detailsURL: nil, isRequired: true),
        ]
        client.checkRunsToReturn = initialChecks
        client.checksNextCursorToReturn = "checks-cursor-1"
        client.checksPageToReturn = ChecksPage(checkRuns: paginatedChecks, nextCursor: nil)
        let (vm, _) = makeViewModel(client: client)

        vm.selectPR(makePR())
        try await waitForLoad(vm)

        #expect(vm.checkRuns.count == 3)
        #expect(vm.checkRuns[0].name == "lint")
        #expect(vm.checkRuns[1].name == "build")
        #expect(vm.checkRuns[2].name == "test")
        #expect(client.fetchChecksCallCount == 1)
    }
}
