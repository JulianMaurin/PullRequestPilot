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

    @Test("identical events posted in quick succession are deduped")
    func dedupeWindow() {
        let center = EventCenter()
        center.post(.error(.unauthorized))
        center.post(.error(.unauthorized))
        center.post(.error(.unauthorized))
        #expect(center.events.count == 1)
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
