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
        // Wait for fetch
        try await Task.sleep(for: .milliseconds(50))

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
        try await Task.sleep(for: .milliseconds(50))

        #expect(vm.timelineEvents.count == 2)
        #expect(vm.isLoading == false)
    }

    @Test("selectPR handles fetch error")
    func selectHandlesError() async throws {
        let client = MockGitHubClient()
        client.errorToThrow = GitHubClientError.networkError(URLError(.notConnectedToInternet))
        let (vm, _) = makeViewModel(client: client)

        vm.selectPR(makePR())
        try await Task.sleep(for: .milliseconds(50))

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
        try await Task.sleep(for: .milliseconds(50))

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
        try await Task.sleep(for: .milliseconds(50))

        #expect(vm.selectedPR?.id == "PR_2")
    }
}
