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

    private func makePR(id: String = "PR_1") throws -> PullRequest {
        try TestPullRequestFactory.make(id: id)
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

    // MARK: - Selection

    @Test("selectPR sets selectedPR")
    func selectSetsSelectedPR() async throws {
        let (vm, _) = makeViewModel()
        let pr = try makePR()
        vm.selectPR(pr)
        #expect(vm.selectedPR?.id == pr.id)
    }

    @Test("selectPR same PR twice deselects")
    func selectSamePRDeselects() async throws {
        let (vm, _) = makeViewModel()
        let pr = try makePR()
        vm.selectPR(pr)
        vm.selectPR(pr)
        #expect(vm.selectedPR == nil)
    }

    @Test("deselect clears all state")
    func deselectClearsState() async throws {
        let client = MockGitHubClient()
        await client.setTimelineEventsToReturn([makeTimelineEvent()])
        let (vm, _) = makeViewModel(client: client)

        let pr = try makePR()
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
        await client.setTimelineEventsToReturn(events)
        let (vm, _) = makeViewModel(client: client)

        vm.selectPR(try makePR())
        try await waitForLoad(vm)

        #expect(vm.timelineEvents.count == 2)
        #expect(vm.isLoading == false)
    }

    @Test("selectPR handles fetch error")
    func selectHandlesError() async throws {
        let client = MockGitHubClient()
        await client.setErrorToThrow(GitHubClientError.networkError(URLError(.notConnectedToInternet)))
        let (vm, _) = makeViewModel(client: client)

        vm.selectPR(try makePR())
        try await waitForLoad(vm)

        #expect(vm.error != nil)
        #expect(vm.timelineEvents.isEmpty)
        #expect(vm.isLoading == false)
    }

    @Test("selectPR with empty timeline shows empty state")
    func selectEmptyTimeline() async throws {
        let client = MockGitHubClient()
        await client.setTimelineEventsToReturn([])
        let (vm, _) = makeViewModel(client: client)

        vm.selectPR(try makePR())
        try await waitForLoad(vm)

        #expect(vm.timelineEvents.isEmpty)
        #expect(vm.error == nil)
        #expect(vm.isLoading == false)
    }

    @Test("selecting different PR cancels previous fetch")
    func selectDifferentPRCancelsPrevious() async throws {
        let client = MockGitHubClient()
        await client.setTimelineEventsToReturn([makeTimelineEvent()])
        let (vm, _) = makeViewModel(client: client)

        vm.selectPR(try makePR(id: "PR_1"))
        vm.selectPR(try makePR(id: "PR_2"))
        try await waitForLoad(vm)

        #expect(vm.selectedPR?.id == "PR_2")
    }

    // MARK: - Network Error State

    @Test("selectPR sets isNetworkError on network failure")
    func selectSetsNetworkError() async throws {
        let client = MockGitHubClient()
        await client.setErrorToThrow(GitHubClientError.networkError(URLError(.notConnectedToInternet)))
        let (vm, _) = makeViewModel(client: client)

        vm.selectPR(try makePR())
        try await waitForLoad(vm)

        #expect(vm.isNetworkError)
        #expect(vm.error != nil)
    }

    @Test("selectPR does not set isNetworkError for non-network errors")
    func selectDoesNotSetNetworkErrorForOtherErrors() async throws {
        let client = MockGitHubClient()
        await client.setErrorToThrow(GitHubClientError.unauthorized)
        let (vm, _) = makeViewModel(client: client)

        vm.selectPR(try makePR())
        try await waitForLoad(vm)

        #expect(!vm.isNetworkError)
        #expect(vm.error != nil)
    }

    @Test("deselect clears isNetworkError")
    func deselectClearsNetworkError() async throws {
        let client = MockGitHubClient()
        await client.setErrorToThrow(GitHubClientError.networkError(URLError(.timedOut)))
        let (vm, _) = makeViewModel(client: client)

        vm.selectPR(try makePR())
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
        await client.setReviewersToReturn(reviewers)
        let (vm, _) = makeViewModel(client: client)

        vm.selectPR(try makePR())
        try await waitForLoad(vm)

        #expect(vm.reviewers.count == 2)
        guard vm.reviewers.count == 2 else { return }
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
            CheckRun(id: "c1", name: "lint", status: .completed, conclusion: .success, detailsURL: nil, isRequired: false, workflowRunID: nil, startedAt: nil),
        ]
        let paginatedChecks = [
            CheckRun(id: "c2", name: "build", status: .completed, conclusion: .success, detailsURL: nil, isRequired: true, workflowRunID: nil, startedAt: nil),
            CheckRun(id: "c3", name: "test", status: .completed, conclusion: .failure, detailsURL: nil, isRequired: true, workflowRunID: nil, startedAt: nil),
        ]
        await client.setCheckRunsToReturn(initialChecks)
        await client.setChecksNextCursorToReturn("checks-cursor-1")
        await client.setChecksPageToReturn(ChecksPage(checkRuns: paginatedChecks, nextCursor: nil))
        let (vm, _) = makeViewModel(client: client)

        vm.selectPR(try makePR())
        try await waitForLoad(vm)

        #expect(vm.checkRuns.count == 3)
        guard vm.checkRuns.count == 3 else { return }
        #expect(vm.checkRuns[0].name == "lint")
        #expect(vm.checkRuns[1].name == "build")
        #expect(vm.checkRuns[2].name == "test")
        #expect(await client.fetchChecksCallCount == 1)
    }

    // MARK: - Pagination Cancellation

    /// Wait until a fetch is suspended at the mock's gate (page in flight).
    private func waitForGateSuspension(
        _ client: PaginatingMockGitHubClient,
        timeout: Duration = .milliseconds(2000)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await client.isGateSuspended), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await client.isGateSuspended)
    }

    @Test("deselect during timeline pagination stops subsequent page fetches")
    func deselectStopsTimelinePagination() async throws {
        let client = PaginatingMockGitHubClient(gatedCall: .firstTimelineCall)
        let vm = PRDetailViewModel(gitHubClient: client)

        vm.selectPR(try makePR(id: "PR_1"))
        try await waitForGateSuspension(client)

        vm.deselect()
        try #require(await client.resumeGate())

        // The second fetch's normal completion is the barrier proving the
        // cancelled task had every opportunity to keep paginating.
        vm.selectPR(try makePR(id: "PR_2"))
        try await waitForLoad(vm)

        #expect(await client.timelineCallCount(nodeID: "PR_1") <= 2)
    }

    @Test("deselect during checks pagination stops subsequent page fetches")
    func deselectStopsChecksPagination() async throws {
        let client = PaginatingMockGitHubClient(gatedCall: .firstChecksCall)
        let vm = PRDetailViewModel(gitHubClient: client)

        vm.selectPR(try makePR(id: "PR_1"))
        try await waitForGateSuspension(client)

        vm.deselect()
        try #require(await client.resumeGate())

        vm.selectPR(try makePR(id: "PR_2"))
        try await waitForLoad(vm)

        #expect(await client.checksCallCount(nodeID: "PR_1") <= 2)
    }

    // MARK: - updateSelectedPR

    @Test("updateSelectedPR updates when ID matches")
    func updateSelectedPRMatching() async throws {
        let (vm, _) = makeViewModel()
        let pr = try makePR(id: "PR_1")
        vm.selectPR(pr)
        try await waitForLoad(vm)

        let updatedPR = try TestPullRequestFactory.make(id: "PR_1", title: "Updated Title")
        vm.updateSelectedPR(updatedPR)

        #expect(vm.selectedPR?.title == "Updated Title")
    }

    @Test("updateSelectedPR is no-op when ID does not match")
    func updateSelectedPRNonMatching() async throws {
        let (vm, _) = makeViewModel()
        let pr = try makePR(id: "PR_1")
        vm.selectPR(pr)
        try await waitForLoad(vm)

        let otherPR = try TestPullRequestFactory.make(id: "PR_OTHER", title: "Other")
        vm.updateSelectedPR(otherPR)

        #expect(vm.selectedPR?.id == "PR_1")
        #expect(vm.selectedPR?.title != "Other")
    }

    @Test("updateSelectedPR is no-op when nothing selected")
    func updateSelectedPRNoSelection() throws {
        let (vm, _) = makeViewModel()
        let pr = try TestPullRequestFactory.make(id: "PR_1")
        vm.updateSelectedPR(pr)
        #expect(vm.selectedPR == nil)
    }
}

// MARK: - Paginating Mock

/// Every page returns a fresh cursor, so pagination only stops at the loop's
/// own bounds — cancellation or maxPages. One designated call suspends until
/// `resumeGate()`, letting a test cancel while that page is in flight
/// (mirroring RequestCoalescer, which completes in-flight requests for
/// cancelled callers).
private actor PaginatingMockGitHubClient: GitHubClientProtocol {

    enum GatedCall {
        case firstTimelineCall
        case firstChecksCall
    }

    private let gatedCall: GatedCall
    private var gateContinuation: CheckedContinuation<Void, Never>?
    private var timelineCallCounts: [String: Int] = [:]
    private var checksCallCounts: [String: Int] = [:]
    private var totalTimelineCalls = 0
    private var totalChecksCalls = 0

    init(gatedCall: GatedCall) {
        self.gatedCall = gatedCall
    }

    var isGateSuspended: Bool { gateContinuation != nil }

    func timelineCallCount(nodeID: String) -> Int { timelineCallCounts[nodeID, default: 0] }

    func checksCallCount(nodeID: String) -> Int { checksCallCounts[nodeID, default: 0] }

    /// Returns false if no call was suspended at the gate.
    func resumeGate() -> Bool {
        guard let continuation = gateContinuation else { return false }
        gateContinuation = nil
        continuation.resume()
        return true
    }

    func fetchTimeline(
        nodeID: String,
        cursor: String?,
        eventPageOffset: Int,
        checksPageOffset: Int
    ) async throws -> TimelinePage {
        totalTimelineCalls += 1
        timelineCallCounts[nodeID, default: 0] += 1
        if gatedCall == .firstTimelineCall, totalTimelineCalls == 1 {
            await withCheckedContinuation { gateContinuation = $0 }
        }
        switch gatedCall {
        case .firstTimelineCall:
            return TimelinePage(
                events: [],
                checkRuns: [],
                reviewers: [],
                nextCursor: "timeline-cursor-\(totalTimelineCalls)",
                checksNextCursor: nil
            )
        case .firstChecksCall:
            // Single timeline page whose checks continue via fetchChecks.
            return TimelinePage(
                events: [],
                checkRuns: [],
                reviewers: [],
                nextCursor: nil,
                checksNextCursor: "checks-start-cursor-\(totalTimelineCalls)"
            )
        }
    }

    func fetchChecks(nodeID: String, cursor: String, checksPageOffset: Int) async throws -> ChecksPage {
        totalChecksCalls += 1
        checksCallCounts[nodeID, default: 0] += 1
        if gatedCall == .firstChecksCall, totalChecksCalls == 1 {
            await withCheckedContinuation { gateContinuation = $0 }
        }
        return ChecksPage(checkRuns: [], nextCursor: "checks-cursor-\(totalChecksCalls)")
    }

    func fetchPullRequests(query: String, cursor: String?, pageSize: Int) async throws -> PullRequestPage {
        PullRequestPage(pullRequests: [], nextCursor: nil)
    }

    func fetchViewer() async throws -> (login: String, avatarURL: URL?) {
        (login: "testuser", avatarURL: nil)
    }

    func validateToken(_ token: String) async throws -> (login: String, avatarURL: URL?) {
        (login: "testuser", avatarURL: nil)
    }

    func setDraft(pullRequestID: String, isDraft: Bool) async throws {}
}
