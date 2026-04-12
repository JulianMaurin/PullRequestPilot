import Testing
import Foundation
@testable import PullRequestPilot

@MainActor
@Suite("PRDetailViewModel.retry")
struct PRDetailRetryTests {

    private func makePR(id: String = "PR_1") -> PullRequest {
        TestPullRequestFactory.make(id: id)
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

    @Test("retry re-fetches timeline without deselecting")
    func retryRefetchesWithoutDeselecting() async throws {
        let client = MockGitHubClient()
        client.errorToThrow = GitHubClientError.networkError(URLError(.timedOut))
        let vm = PRDetailViewModel(gitHubClient: client)

        // Select PR — will error
        vm.selectPR(makePR())
        try await waitForLoad(vm)
        #expect(vm.error != nil)
        #expect(vm.selectedPR != nil)

        // Fix the client
        client.errorToThrow = nil
        client.timelineEventsToReturn = [
            TimelineEvent(id: "1", kind: .comment, actor: nil, timestamp: Date(), body: nil)
        ]

        // Retry — should keep selection and re-fetch
        vm.retry()
        try await waitForLoad(vm)
        #expect(vm.selectedPR != nil)
        #expect(vm.error == nil)
        #expect(vm.timelineEvents.count == 1)
    }

    @Test("retry is no-op when no PR selected")
    func retryNoOpWhenNoSelection() {
        let client = MockGitHubClient()
        let vm = PRDetailViewModel(gitHubClient: client)
        vm.retry()
        // Should not crash, no fetch triggered
        #expect(vm.selectedPR == nil)
        #expect(client.fetchTimelineCallCount == 0)
    }
}
