import Foundation
import os
@testable import PullRequestPilot

/// Thread-safe mock. All state is guarded by a single lock because Swift
/// Testing runs tests in parallel and per-test task groups (e.g.,
/// `DashboardViewModel.refreshAll`) invoke `fetchPullRequests` concurrently
/// from multiple tasks against the same mock instance.
final class MockGitHubClient: GitHubClientProtocol, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()

    private var _pullRequestsToReturn: [PullRequest] = []
    private var _nextCursorToReturn: String?
    private var _viewerLoginToReturn: String = "testuser"
    private var _viewerAvatarURLToReturn: URL?
    private var _timelineEventsToReturn: [TimelineEvent] = []
    private var _timelineNextCursorToReturn: String?
    private var _reviewersToReturn: [Reviewer] = []
    private var _checksNextCursorToReturn: String?
    private var _checksPageToReturn: ChecksPage?
    private var _errorToThrow: Error?
    private var _fetchViewerError: Error?
    private var _validateTokenError: Error?
    private var _checkRunsToReturn: [CheckRun] = []
    private var _fetchPullRequestsCallCount = 0
    private var _fetchTimelineCallCount = 0
    private var _fetchChecksCallCount = 0
    private var _validateTokenCallCount = 0
    private var _receivedQueries: [String] = []
    private var _receivedCursors: [String?] = []
    private var _receivedValidateTokens: [String] = []

    // MARK: - Accessors (tests read/write through these; lock guards every access)

    var pullRequestsToReturn: [PullRequest] {
        get { lock.withLock { _pullRequestsToReturn } }
        set { lock.withLock { _pullRequestsToReturn = newValue } }
    }

    var nextCursorToReturn: String? {
        get { lock.withLock { _nextCursorToReturn } }
        set { lock.withLock { _nextCursorToReturn = newValue } }
    }

    var viewerLoginToReturn: String {
        get { lock.withLock { _viewerLoginToReturn } }
        set { lock.withLock { _viewerLoginToReturn = newValue } }
    }

    var viewerAvatarURLToReturn: URL? {
        get { lock.withLock { _viewerAvatarURLToReturn } }
        set { lock.withLock { _viewerAvatarURLToReturn = newValue } }
    }

    var timelineEventsToReturn: [TimelineEvent] {
        get { lock.withLock { _timelineEventsToReturn } }
        set { lock.withLock { _timelineEventsToReturn = newValue } }
    }

    var timelineNextCursorToReturn: String? {
        get { lock.withLock { _timelineNextCursorToReturn } }
        set { lock.withLock { _timelineNextCursorToReturn = newValue } }
    }

    var reviewersToReturn: [Reviewer] {
        get { lock.withLock { _reviewersToReturn } }
        set { lock.withLock { _reviewersToReturn = newValue } }
    }

    var checksNextCursorToReturn: String? {
        get { lock.withLock { _checksNextCursorToReturn } }
        set { lock.withLock { _checksNextCursorToReturn = newValue } }
    }

    var checksPageToReturn: ChecksPage? {
        get { lock.withLock { _checksPageToReturn } }
        set { lock.withLock { _checksPageToReturn = newValue } }
    }

    var errorToThrow: Error? {
        get { lock.withLock { _errorToThrow } }
        set { lock.withLock { _errorToThrow = newValue } }
    }

    var fetchViewerError: Error? {
        get { lock.withLock { _fetchViewerError } }
        set { lock.withLock { _fetchViewerError = newValue } }
    }

    var validateTokenError: Error? {
        get { lock.withLock { _validateTokenError } }
        set { lock.withLock { _validateTokenError = newValue } }
    }

    var checkRunsToReturn: [CheckRun] {
        get { lock.withLock { _checkRunsToReturn } }
        set { lock.withLock { _checkRunsToReturn = newValue } }
    }

    var fetchPullRequestsCallCount: Int {
        get { lock.withLock { _fetchPullRequestsCallCount } }
        set { lock.withLock { _fetchPullRequestsCallCount = newValue } }
    }
    var fetchTimelineCallCount: Int {
        get { lock.withLock { _fetchTimelineCallCount } }
        set { lock.withLock { _fetchTimelineCallCount = newValue } }
    }
    var fetchChecksCallCount: Int {
        get { lock.withLock { _fetchChecksCallCount } }
        set { lock.withLock { _fetchChecksCallCount = newValue } }
    }
    var validateTokenCallCount: Int {
        get { lock.withLock { _validateTokenCallCount } }
        set { lock.withLock { _validateTokenCallCount = newValue } }
    }
    var receivedQueries: [String] { lock.withLock { _receivedQueries } }
    var receivedCursors: [String?] { lock.withLock { _receivedCursors } }
    var receivedValidateTokens: [String] { lock.withLock { _receivedValidateTokens } }

    // MARK: - Protocol

    func fetchPullRequests(query: String, cursor: String?) async throws -> PullRequestPage {
        let (error, prs, nextCursor) = lock.withLock { () -> (Error?, [PullRequest], String?) in
            _fetchPullRequestsCallCount += 1
            _receivedQueries.append(query)
            _receivedCursors.append(cursor)
            return (_errorToThrow, _pullRequestsToReturn, _nextCursorToReturn)
        }
        if let error { throw error }
        return PullRequestPage(pullRequests: prs, nextCursor: nextCursor, skippedNodeCount: 0)
    }

    func fetchTimeline(nodeID: String, cursor: String?, eventPageOffset: Int, checksPageOffset: Int) async throws -> TimelinePage {
        let (error, events, checkRuns, reviewers, nextCursor, checksNextCursor) = lock.withLock { () -> (Error?, [TimelineEvent], [CheckRun], [Reviewer], String?, String?) in
            _fetchTimelineCallCount += 1
            return (_errorToThrow, _timelineEventsToReturn, _checkRunsToReturn, _reviewersToReturn, _timelineNextCursorToReturn, _checksNextCursorToReturn)
        }
        if let error { throw error }
        return TimelinePage(events: events, checkRuns: checkRuns, reviewers: reviewers, nextCursor: nextCursor, checksNextCursor: checksNextCursor)
    }

    func fetchChecks(nodeID: String, cursor: String, checksPageOffset: Int) async throws -> ChecksPage {
        let (error, page) = lock.withLock { () -> (Error?, ChecksPage?) in
            _fetchChecksCallCount += 1
            return (_errorToThrow, _checksPageToReturn)
        }
        if let error { throw error }
        return page ?? ChecksPage(checkRuns: [], nextCursor: nil)
    }

    func fetchViewer() async throws -> (login: String, avatarURL: URL?) {
        let (viewerError, genericError, login, avatar) = lock.withLock { () -> (Error?, Error?, String, URL?) in
            return (_fetchViewerError, _errorToThrow, _viewerLoginToReturn, _viewerAvatarURLToReturn)
        }
        if let viewerError { throw viewerError }
        if let genericError { throw genericError }
        return (login: login, avatarURL: avatar)
    }

    func validateToken(_ token: String) async throws -> (login: String, avatarURL: URL?) {
        let (validateError, viewerError, genericError, login, avatar) = lock.withLock { () -> (Error?, Error?, Error?, String, URL?) in
            _validateTokenCallCount += 1
            _receivedValidateTokens.append(token)
            return (_validateTokenError, _fetchViewerError, _errorToThrow, _viewerLoginToReturn, _viewerAvatarURLToReturn)
        }

        if let validateError { throw validateError }
        if let viewerError { throw viewerError }
        if let genericError { throw genericError }
        return (login: login, avatarURL: avatar)
    }
}
