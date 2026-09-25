import Foundation
@testable import PullRequestPilot

/// Actor-backed mock. Swift Testing runs tests in parallel and per-test task
/// groups (e.g. `DashboardViewModel.refreshAll`) invoke `fetchPullRequests`
/// concurrently from multiple tasks against the same mock instance — actor
/// isolation serializes those reads/writes without a lock.
///
/// External callers must `await` every read and write. `MockGitHubClient`
/// previously wrapped an `OSAllocatedUnfairLock` behind a `@unchecked Sendable`
/// class; that pattern is banned by CLAUDE.md.
actor MockGitHubClient: GitHubClientProtocol {

    // MARK: - Configurable return values

    var pullRequestsToReturn: [PullRequest] = []
    var nextCursorToReturn: String?
    var viewerLoginToReturn: String = "testuser"
    var viewerAvatarURLToReturn: URL?
    var timelineEventsToReturn: [TimelineEvent] = []
    var timelineNextCursorToReturn: String?
    var reviewersToReturn: [Reviewer] = []
    var checksNextCursorToReturn: String?
    var checksPageToReturn: ChecksPage?
    var errorToThrow: Error?
    var fetchViewerError: Error?
    var validateTokenError: Error?
    var classicTokenScopesToReturn: Set<String>?
    var checkRunsToReturn: [CheckRun] = []
    var setDraftError: Error?

    // MARK: - Call counters & recordings

    struct DraftStateRequest: Equatable, Sendable {
        let pullRequestID: String
        let isDraft: Bool
    }

    var fetchPullRequestsCallCount = 0
    var fetchTimelineCallCount = 0
    var fetchChecksCallCount = 0
    var validateTokenCallCount = 0
    var receivedQueries: [String] = []
    var receivedCursors: [String?] = []
    var receivedPageSizes: [Int] = []
    var receivedValidateTokens: [String] = []
    var receivedDraftStateRequests: [DraftStateRequest] = []

    // MARK: - Setters
    //
    // Swift actors don't allow cross-actor `var` assignment (`await mock.foo = x`
    // is rejected). Tests call these setters instead; reads (`await mock.foo`)
    // continue to work because cross-actor *reads* of isolated `var`s are legal.

    func setPullRequestsToReturn(_ value: [PullRequest]) { pullRequestsToReturn = value }
    func setNextCursorToReturn(_ value: String?) { nextCursorToReturn = value }
    func setViewerLogin(_ value: String) { viewerLoginToReturn = value }
    func setViewerAvatarURL(_ value: URL?) { viewerAvatarURLToReturn = value }
    func setTimelineEventsToReturn(_ value: [TimelineEvent]) { timelineEventsToReturn = value }
    func setTimelineNextCursorToReturn(_ value: String?) { timelineNextCursorToReturn = value }
    func setReviewersToReturn(_ value: [Reviewer]) { reviewersToReturn = value }
    func setChecksNextCursorToReturn(_ value: String?) { checksNextCursorToReturn = value }
    func setChecksPageToReturn(_ value: ChecksPage?) { checksPageToReturn = value }
    func setErrorToThrow(_ value: Error?) { errorToThrow = value }
    func setFetchViewerError(_ value: Error?) { fetchViewerError = value }
    func setValidateTokenError(_ value: Error?) { validateTokenError = value }
    func setClassicTokenScopes(_ value: Set<String>?) { classicTokenScopesToReturn = value }
    func setCheckRunsToReturn(_ value: [CheckRun]) { checkRunsToReturn = value }
    func setFetchPullRequestsCallCount(_ value: Int) { fetchPullRequestsCallCount = value }
    func setSetDraftError(_ value: Error?) { setDraftError = value }

    // MARK: - Protocol

    func fetchPullRequests(query: String, cursor: String?, pageSize: Int) async throws -> PullRequestPage {
        fetchPullRequestsCallCount += 1
        receivedQueries.append(query)
        receivedCursors.append(cursor)
        receivedPageSizes.append(pageSize)
        if let errorToThrow { throw errorToThrow }
        return PullRequestPage(
            pullRequests: pullRequestsToReturn,
            nextCursor: nextCursorToReturn
        )
    }

    func fetchTimeline(
        nodeID: String,
        cursor: String?,
        eventPageOffset: Int,
        checksPageOffset: Int
    ) async throws -> TimelinePage {
        fetchTimelineCallCount += 1
        if let errorToThrow { throw errorToThrow }
        return TimelinePage(
            events: timelineEventsToReturn,
            checkRuns: checkRunsToReturn,
            reviewers: reviewersToReturn,
            nextCursor: timelineNextCursorToReturn,
            checksNextCursor: checksNextCursorToReturn
        )
    }

    func fetchChecks(nodeID: String, cursor: String, checksPageOffset: Int) async throws -> ChecksPage {
        fetchChecksCallCount += 1
        if let errorToThrow { throw errorToThrow }
        return checksPageToReturn ?? ChecksPage(checkRuns: [], nextCursor: nil)
    }

    func fetchViewer() async throws -> (login: String, avatarURL: URL?) {
        if let fetchViewerError { throw fetchViewerError }
        if let errorToThrow { throw errorToThrow }
        return (login: viewerLoginToReturn, avatarURL: viewerAvatarURLToReturn)
    }

    func validateToken(_ token: String) async throws -> TokenValidation {
        validateTokenCallCount += 1
        receivedValidateTokens.append(token)
        if let validateTokenError { throw validateTokenError }
        if let fetchViewerError { throw fetchViewerError }
        if let errorToThrow { throw errorToThrow }
        return TokenValidation(login: viewerLoginToReturn, avatarURL: viewerAvatarURLToReturn, classicTokenScopes: classicTokenScopesToReturn)
    }

    func setDraft(pullRequestID: String, isDraft: Bool) async throws {
        receivedDraftStateRequests.append(DraftStateRequest(pullRequestID: pullRequestID, isDraft: isDraft))
        if let setDraftError { throw setDraftError }
    }
}
