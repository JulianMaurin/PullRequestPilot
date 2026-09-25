import Testing
import Foundation
@testable import PullRequestPilot

@MainActor
@Suite("PRDetailViewModel.retry")
struct PRDetailRetryTests {

    private func makePR(id: String = "PR_1") throws -> PullRequest {
        try TestPullRequestFactory.make(id: id)
    }

    /// Wait for the fire-and-forget Task to start and finish loading.
    private func waitForLoad(_ vm: PRDetailViewModel, timeout: Duration = .milliseconds(2000)) async throws {
        let deadline = ContinuousClock.now + timeout
        // Phase 1: yield until the Task sets isLoading = true (task started)
        while !vm.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        // Phase 2: wait for isLoading to go back to false (task finished)
        while vm.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("retry re-fetches timeline without deselecting")
    func retryRefetchesWithoutDeselecting() async throws {
        let client = MockGitHubClient()
        await client.setErrorToThrow(GitHubClientError.networkError(URLError(.timedOut)))
        let vm = PRDetailViewModel(gitHubClient: client)

        // Select PR — will error
        vm.selectPR(try makePR())
        try await waitForLoad(vm)
        #expect(vm.error != nil)
        #expect(vm.selectedPR != nil)

        // Fix the client
        await client.setErrorToThrow(nil)
        await client.setTimelineEventsToReturn([
            TimelineEvent(id: "1", kind: .comment, actor: nil, timestamp: Date(), body: nil)
        ])

        // Retry — should keep selection and re-fetch
        vm.retry()
        try await waitForLoad(vm)
        #expect(vm.selectedPR != nil)
        #expect(vm.error == nil)
        #expect(vm.timelineEvents.count == 1)
    }

    @Test("retry is no-op when no PR selected")
    func retryNoOpWhenNoSelection() async {
        let client = MockGitHubClient()
        let vm = PRDetailViewModel(gitHubClient: client)
        vm.retry()
        // Should not crash, no fetch triggered
        #expect(vm.selectedPR == nil)
        #expect(await client.fetchTimelineCallCount == 0)
    }
}
