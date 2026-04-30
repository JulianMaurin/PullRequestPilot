import Testing
import Foundation
@testable import PullRequestPilot

@Suite("EventCenter")
@MainActor
struct EventCenterTests {

    @Test("post stores the event and exposes it via activeEvents")
    func postStoresEvent() {
        let center = EventCenter()
        center.post(.error(.unauthorized))
        #expect(center.activeEvents.count == 1)
        #expect(center.events.first?.appError == .unauthorized)
    }

    @Test("dismiss removes event from activeEvents but keeps it in events")
    func dismissKeepsEvent() throws {
        let center = EventCenter()
        center.post(.info("hello"))
        let id = try #require(center.events.first?.id)
        center.dismiss(id)
        #expect(center.activeEvents.isEmpty)
        #expect(center.events.count == 1)
    }

    @Test("reporter posts through to the center")
    func reporterPostsThrough() async {
        let center = EventCenter()
        let reporter = center.reporter()
        reporter.postError(.viewerIdentityUnavailable)
        // Reporter hops through Task { @MainActor } — yield until the post lands.
        for _ in 0..<20 where center.events.isEmpty {
            await Task.yield()
        }
        #expect(center.events.first?.appError == .viewerIdentityUnavailable)
    }

    // MARK: - Dedupe while visible

    @Test("rapid same-payload posts coalesce into one event")
    func samePayloadRapidFirePosts_resultInSingleEvent() {
        let center = EventCenter()
        center.post(.error(.unauthorized))
        center.post(.error(.unauthorized))
        center.post(.error(.unauthorized))
        #expect(center.events.count == 1)
        #expect(center.activeEvents.count == 1)
    }

    @Test("same-payload re-post past the old 3s window still coalesces while visible")
    func samePayloadRePost_pastOldDedupeWindow_stillCoalescesWhileVisible() async {
        let clock = TestClock()
        let center = EventCenter(clock: clock)

        center.post(AppEvent(payload: .info("ongoing"), autoDismissAfter: .seconds(8)))
        clock.advance(by: .seconds(4)) // past the legacy 3s suppression window
        await yieldRepeatedly()

        center.post(AppEvent(payload: .info("ongoing"), autoDismissAfter: .seconds(8)))
        #expect(center.events.count == 1, "second post must not insert a new event while the first is still visible")
        #expect(center.activeEvents.count == 1)
    }

    @Test("same-payload re-post resets the auto-dismiss timer")
    func samePayloadRePost_refreshesAutoDismissTimer() async throws {
        let clock = TestClock()
        let center = EventCenter(clock: clock)

        center.post(AppEvent(payload: .info("ongoing"), autoDismissAfter: .seconds(8)))
        clock.advance(by: .seconds(4))
        await yieldRepeatedly()

        center.post(AppEvent(payload: .info("ongoing"), autoDismissAfter: .seconds(8)))
        // Yield so the refreshed dismiss task computes its deadline
        // (clock.now + 8s) before any further advance — TestClock reads `now`
        // lazily inside the task body, so an advance before the body runs
        // would shift the deadline forward.
        await yieldRepeatedly()

        // T = 4s post-second-post = 8s post-first-post (the original timer
        // would have fired now had it not been cancelled by the refresh).
        clock.advance(by: .seconds(4))
        await yieldRepeatedly()
        #expect(!center.activeEvents.isEmpty, "timer must be reset on the second post — toast still visible past the original 8s")

        // T = 9s post-second-post = beyond the refreshed 8s window
        clock.advance(by: .seconds(5))
        try await waitUntil { center.activeEvents.isEmpty }
        #expect(center.activeEvents.isEmpty)
    }

    @Test("same-payload re-post after manual dismiss inserts a new event")
    func samePayloadRePost_afterManualDismiss_insertsNewEvent() throws {
        let center = EventCenter()
        center.post(.error(.network(underlying: "offline")))
        let firstID = try #require(center.events.first?.id)
        center.dismiss(firstID)

        center.post(.error(.network(underlying: "offline")))
        #expect(center.events.count == 2)
        #expect(center.activeEvents.count == 1)
        #expect(center.activeEvents.first?.id != firstID)
    }

    @Test("same-payload re-post after auto-dismiss inserts a new event")
    func samePayloadRePost_afterAutoDismiss_insertsNewEvent() async throws {
        let center = EventCenter()
        center.post(AppEvent(payload: .info("hi"), autoDismissAfter: .milliseconds(50)))
        try await waitUntil { center.activeEvents.isEmpty }

        center.post(AppEvent(payload: .info("hi"), autoDismissAfter: .milliseconds(50)))
        #expect(center.events.count == 2)
        #expect(center.activeEvents.count == 1)
    }

    @Test("different payloads stay independent (distinct associated values)")
    func differentPayloads_areIndependent() {
        let center = EventCenter()
        center.post(.error(.serverError(statusCode: 503)))
        center.post(.error(.serverError(statusCode: 502)))
        #expect(center.events.count == 2)
        #expect(center.activeEvents.count == 2)
    }

    @Test("pinned error re-post is a no-op")
    func pinnedError_rePost_isNoOp() throws {
        let center = EventCenter()
        center.post(.error(.unauthorized))
        let firstID = try #require(center.events.first?.id)

        center.post(.error(.unauthorized))
        #expect(center.events.count == 1)
        #expect(center.events.first?.id == firstID)
        #expect(center.activeEvents.count == 1)
    }

    @Test("dismissAll(matching:) removes events matching the predicate")
    func dismissAllMatching() {
        let center = EventCenter()
        center.post(.error(.unauthorized))
        center.post(.error(.viewerIdentityUnavailable))
        center.dismissAll { if case .unauthorized = $0 { return true } else { return false } }
        #expect(center.activeEvents.count == 1)
        #expect(center.activeEvents.first?.appError == .viewerIdentityUnavailable)
    }

    @Test("events beyond maxHistory are dropped")
    func boundedHistory() {
        let center = EventCenter(maxHistory: 2)
        center.post(.info("a"))
        center.post(.info("b"))
        center.post(.info("c"))
        #expect(center.events.count == 2)
        // Newest first
        #expect(center.events.first?.message == "c")
    }

    // MARK: - Auto-dismiss defaults

    @Test("transient errors auto-dismiss at 8s by default")
    func transientErrorDefaultDuration() {
        let event = AppEvent.error(.network(underlying: "offline"))
        #expect(event.autoDismissAfter == .seconds(8))
    }

    @Test("action-required errors stay pinned (no auto-dismiss)")
    func requiresActionErrorStaysPinned() {
        #expect(AppEvent.error(.unauthorized).autoDismissAfter == nil)
        #expect(AppEvent.error(.permissionDenied(detail: nil)).autoDismissAfter == nil)
        #expect(AppEvent.error(.bookmarkPruned(count: 2)).autoDismissAfter == nil)
        #expect(AppEvent.error(.tokenSaveFailed(underlying: "x")).autoDismissAfter == nil)
        #expect(AppEvent.error(.decodeCorruption(subsystem: "views", backupPath: nil)).autoDismissAfter == nil)
    }

    @Test("explicit autoDismissAfter overrides the smart default")
    func explicitOverrideWins() {
        let event = AppEvent.error(.unauthorized, autoDismissAfter: .seconds(3))
        #expect(event.autoDismissAfter == .seconds(3))
    }

    // MARK: - Pause / resume

    @Test("auto-dismiss fires after the scheduled duration")
    func autoDismissFires() async throws {
        let center = EventCenter()
        center.post(AppEvent(payload: .info("hi"), autoDismissAfter: .milliseconds(50)))
        #expect(center.activeEvents.count == 1)

        try await waitUntil { center.activeEvents.isEmpty }
        #expect(center.activeEvents.isEmpty)
    }

    @Test("pauseAutoDismiss prevents the scheduled dismissal from firing")
    func pausePreventsDismissal() async throws {
        let clock = TestClock()
        let center = EventCenter(clock: clock)
        center.post(AppEvent(payload: .info("hi"), autoDismissAfter: .milliseconds(50)))
        let id = try #require(center.events.first?.id)
        center.pauseAutoDismiss(id)

        // Advance well past the original duration — toast must still be active.
        clock.advance(by: .milliseconds(200))
        await yieldRepeatedly()
        #expect(!center.activeEvents.isEmpty)
    }

    @Test("resumeAutoDismiss reschedules after a pause")
    func resumeReschedulesDismissal() async throws {
        let clock = TestClock()
        let center = EventCenter(clock: clock)
        center.post(AppEvent(payload: .info("hi"), autoDismissAfter: .milliseconds(50)))
        let id = try #require(center.events.first?.id)
        center.pauseAutoDismiss(id)
        clock.advance(by: .milliseconds(100))
        await yieldRepeatedly()
        #expect(!center.activeEvents.isEmpty, "pause should hold the toast")

        center.resumeAutoDismiss(id)
        clock.advance(by: .milliseconds(50))
        try await waitUntil { center.activeEvents.isEmpty }
        #expect(center.activeEvents.isEmpty)
    }

    @Test("resumeAutoDismiss called twice does not leave a second stale task")
    func resumeDoesNotLeak() async throws {
        let clock = TestClock()
        let center = EventCenter(clock: clock)
        center.post(AppEvent(payload: .info("hi"), autoDismissAfter: .milliseconds(80)))
        let id = try #require(center.events.first?.id)

        // Two resumes in quick succession — the first scheduled task must be
        // cancelled before the second one takes over, otherwise the first fires
        // earlier than the second's fresh window.
        center.resumeAutoDismiss(id)
        clock.advance(by: .milliseconds(20))
        await yieldRepeatedly()
        center.resumeAutoDismiss(id)

        // 40ms after the 2nd resume: first-scheduled task would have fired by now
        // (80ms from post). If we're still active, replacement worked.
        clock.advance(by: .milliseconds(40))
        await yieldRepeatedly()
        #expect(!center.activeEvents.isEmpty, "2nd resume must cancel the 1st task")
    }

    // MARK: - Helpers

    @MainActor
    private func waitUntil(
        deadlineSeconds: Double = 2.0,
        _ predicate: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(deadlineSeconds))
        while !predicate() {
            if ContinuousClock.now >= deadline { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Yield the current task repeatedly so any other scheduled task (e.g., the
    /// event-center auto-dismiss task that just resumed from a TestClock
    /// advance) gets a chance to observe the resumption before the assertion.
    private func yieldRepeatedly(count: Int = 10) async {
        for _ in 0..<count { await Task.yield() }
    }

}

@Suite("AppError requiresAction")
struct AppErrorRequiresActionTests {

    @Test("errors that need user action are flagged")
    func actionRequiredCases() {
        #expect(AppError.unauthorized.requiresAction)
        #expect(AppError.permissionDenied(detail: nil).requiresAction)
        #expect(AppError.bookmarkPruned(count: 1).requiresAction)
        #expect(AppError.tokenSaveFailed(underlying: "x").requiresAction)
        #expect(AppError.decodeCorruption(subsystem: "views", backupPath: nil).requiresAction)
    }

    @Test("transient errors are not flagged")
    func transientCases() {
        #expect(!AppError.network(underlying: "offline").requiresAction)
        #expect(!AppError.serverError(statusCode: 500).requiresAction)
        #expect(!AppError.rateLimited(resetAt: nil).requiresAction)
        #expect(!AppError.decodeResponse(detail: "x").requiresAction)
        #expect(!AppError.graphQLErrors(["oops"]).requiresAction)
        #expect(!AppError.widgetSaveFailed(underlying: "x").requiresAction)
        #expect(!AppError.externalAppLaunchFailed(appName: "x").requiresAction)
        #expect(!AppError.notificationSystemError(detail: "x").requiresAction)
        #expect(!AppError.logExportFailed(underlying: "x").requiresAction)
        #expect(!AppError.viewerIdentityUnavailable.requiresAction)
        #expect(!AppError.launchAtLoginFailed(underlying: "x").requiresAction)
        #expect(!AppError.bookmarkCreationFailed(path: "/tmp").requiresAction)
    }
}

@Suite("AppError")
struct AppErrorTests {

    @Test("network error is flagged as network failure")
    func networkFailureFlag() {
        #expect(AppError.network(underlying: "offline").isNetworkFailure)
        #expect(!AppError.unauthorized.isNetworkFailure)
    }

    @Test("rate-limited with reset date includes relative phrase")
    func rateLimitedDescription() {
        let future = Date(timeIntervalSinceNow: 120)
        let description = AppError.rateLimited(resetAt: future).errorDescription ?? ""
        #expect(description.localizedStandardContains("rate limit"))
    }

    @Test("bookmarkPruned description pluralizes correctly")
    func bookmarkPrunedPlural() {
        let one = AppError.bookmarkPruned(count: 1).errorDescription ?? ""
        let many = AppError.bookmarkPruned(count: 3).errorDescription ?? ""
        #expect(one.contains("1 directory"))
        #expect(many.contains("3 directories"))
    }
}

@Suite("GitHubClientError mapping")
struct GitHubClientErrorMappingTests {

    @Test("permissionDenied maps to AppError.permissionDenied")
    func permissionDeniedMaps() {
        let clientError = GitHubClientError.permissionDenied(detail: "no scope")
        if case .permissionDenied(let detail) = clientError.asAppError {
            #expect(detail == "no scope")
        } else {
            Issue.record("Expected AppError.permissionDenied, got \(clientError.asAppError)")
        }
    }

    @Test("rateLimited maps and carries resetAt forward")
    func rateLimitedMaps() {
        let clientError = GitHubClientError.rateLimited(retryAfter: 60)
        if case .rateLimited(let resetAt) = clientError.asAppError {
            #expect(resetAt != nil)
        } else {
            Issue.record("Expected AppError.rateLimited")
        }
    }

    @Test("networkError is flagged as network failure")
    func networkErrorFlag() {
        let clientError = GitHubClientError.networkError(URLError(.notConnectedToInternet))
        #expect(clientError.isNetworkFailure)
        #expect(clientError.asAppError.isNetworkFailure)
    }
}
