import Testing
import Foundation
@testable import PullRequestPilot

@Suite("GitHubClient HTTP Error Handling", .serialized, .keychainCleanup)
struct GitHubClientHTTPErrorTests {

    private func makeClient(token: String = "valid-token") -> (client: GitHubClient, http: MockHTTPSession) {
        let http = MockHTTPSession()
        return (GitHubClient(tokenProvider: { token }, session: http.urlSession), http)
    }

    // MARK: - HTTP 403

    @Test("HTTP 403 without rate-limit headers throws permissionDenied")
    func http403WithoutRateHeadersThrowsPermissionDenied() async {
        let (client, http) = makeClient()
        let body = Data(#"{"message":"Resource not accessible by integration"}"#.utf8)
        http.handler = { request in
            try TestHTTP.response(for: request, statusCode: 403, body: body)
        }

        do {
            _ = try await client.fetchPullRequests(query: "is:pr", cursor: nil)
            Issue.record("Should have thrown")
        } catch let error as GitHubClientError {
            if case .permissionDenied(let detail) = error {
                #expect(detail?.contains("Resource not accessible") == true)
            } else {
                Issue.record("Expected permissionDenied, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("HTTP 403 with X-RateLimit-Remaining:0 throws rateLimited")
    func http403WithRateHeadersThrowsRateLimited() async {
        let (client, http) = makeClient()
        http.handler = { request in
            let resetAt = Int(Date.now.timeIntervalSince1970 + 120)
            return try TestHTTP.response(
                for: request,
                statusCode: 403,
                headers: [
                    "X-RateLimit-Remaining": "0",
                    "X-RateLimit-Reset": String(resetAt)
                ]
            )
        }

        do {
            _ = try await client.fetchPullRequests(query: "is:pr", cursor: nil)
            Issue.record("Should have thrown")
        } catch let error as GitHubClientError {
            if case .rateLimited(let retryAfter) = error {
                #expect((retryAfter ?? 0) > 0)
            } else {
                Issue.record("Expected rateLimited, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - GraphQL rate limits reported as HTTP 200

    /// The wait carried by a `.rateLimited` error; records an issue otherwise.
    private func rateLimitedWait(_ fetch: () async throws -> Void) async -> TimeInterval? {
        do {
            try await fetch()
            Issue.record("Expected rateLimited, but the call succeeded")
        } catch GitHubClientError.rateLimited(let retryAfter) {
            return retryAfter
        } catch {
            Issue.record("Expected rateLimited, got \(error)")
        }
        return nil
    }

    @Test("HTTP 200 carrying GitHub's RATE_LIMITED error waits until the quota resets")
    func graphQLPrimaryRateLimit() async throws {
        let (client, http) = makeClient()
        let resetAt = Int(Date.now.timeIntervalSince1970 + 600)
        let body = Data(#"{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded for user ID 1."}]}"#.utf8)
        http.handler = { request in
            try TestHTTP.response(for: request, body: body, headers: [
                "X-RateLimit-Remaining": "0",
                "X-RateLimit-Reset": String(resetAt),
            ])
        }

        let wait = try #require(await rateLimitedWait { _ = try await client.fetchPullRequests(query: "is:pr", cursor: nil) })
        #expect((590...600).contains(wait))
    }

    @Test("HTTP 200 secondary rate-limit message waits a minute when no header says otherwise")
    func graphQLSecondaryRateLimit() async throws {
        let (client, http) = makeClient()
        let body = Data(#"{"errors":[{"message":"You have exceeded a secondary rate limit. Please wait a few minutes before you try again."}]}"#.utf8)
        http.handler = { request in
            try TestHTTP.response(for: request, body: body)
        }

        let wait = await rateLimitedWait { _ = try await client.fetchPullRequests(query: "is:pr", cursor: nil) }
        #expect(wait == 60)
    }

    @Test("a valid response with the quota just exhausted still decodes")
    func exhaustedQuotaWithDataDecodes() async throws {
        let (client, http) = makeClient()
        let body = Data(#"{"data":{"search":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}"#.utf8)
        http.handler = { request in
            try TestHTTP.response(for: request, body: body, headers: ["X-RateLimit-Remaining": "0"])
        }

        let page = try await client.fetchPullRequests(query: "is:pr", cursor: nil)
        #expect(page.pullRequests.isEmpty)
    }

    @Test("validating a token while rate-limited reports a network problem, not an invalid token")
    func rateLimitedTokenValidationIsNotInvalidToken() async throws {
        let (client, http) = makeClient()
        let body = Data(#"{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded for user ID 1."}]}"#.utf8)
        http.handler = { request in
            try TestHTTP.response(for: request, body: body, headers: ["X-RateLimit-Remaining": "0"])
        }
        let identity = IdentityActorTestFactory.make(github: client)

        do {
            try await identity.swap(to: "ghp_valid_but_rate_limited")
            Issue.record("Expected swap to throw")
        } catch let error as AuthError {
            #expect(error.reason == .network)
        }
    }

    // MARK: - Secondary rate limits on 403 / 429

    @Test("HTTP 403 whose message names a secondary rate limit is rate-limited, not permission-denied")
    func http403SecondaryRateLimitMessage() async throws {
        let (client, http) = makeClient()
        let body = Data(#"{"message":"You have exceeded a secondary rate limit. Please wait a few minutes before you try again."}"#.utf8)
        http.handler = { request in
            try TestHTTP.response(for: request, statusCode: 403, body: body)
        }

        let wait = await rateLimitedWait { _ = try await client.fetchPullRequests(query: "is:pr", cursor: nil) }
        #expect(wait == 60)
    }

    @Test("HTTP 429 without Retry-After waits a minute")
    func http429WithoutRetryAfterWaitsAMinute() async throws {
        let (client, http) = makeClient()
        http.handler = { request in
            try TestHTTP.response(for: request, statusCode: 429)
        }

        let wait = await rateLimitedWait { _ = try await client.fetchPullRequests(query: "is:pr", cursor: nil) }
        #expect(wait == 60)
    }

    // MARK: - HTTP 5xx

    @Test("throws serverError on HTTP 500 response")
    func http500ThrowsServerError() async {
        let (client, http) = makeClient()
        http.handler = { request in
            try TestHTTP.response(for: request, statusCode: 500)
        }

        do {
            _ = try await client.fetchPullRequests(query: "is:pr", cursor: nil)
            Issue.record("Should have thrown")
        } catch let error as GitHubClientError {
            if case .serverError(let code) = error {
                #expect(code == 500)
            } else {
                Issue.record("Expected serverError, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("throws serverError on HTTP 502 response")
    func http502ThrowsServerError() async {
        let (client, http) = makeClient()
        http.handler = { request in
            try TestHTTP.response(for: request, statusCode: 502)
        }

        do {
            _ = try await client.fetchPullRequests(query: "is:pr", cursor: nil)
            Issue.record("Should have thrown")
        } catch let error as GitHubClientError {
            if case .serverError(let code) = error {
                #expect(code == 502)
            } else {
                Issue.record("Expected serverError, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - HTTP 4xx (other)

    @Test("throws clientError on HTTP 400 response")
    func http400ThrowsClientError() async {
        let (client, http) = makeClient()
        http.handler = { request in
            try TestHTTP.response(for: request, statusCode: 400)
        }

        do {
            _ = try await client.fetchPullRequests(query: "is:pr", cursor: nil)
            Issue.record("Should have thrown")
        } catch let error as GitHubClientError {
            if case .clientError(let code) = error {
                #expect(code == 400)
            } else {
                Issue.record("Expected clientError, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("throws clientError on HTTP 422 response")
    func http422ThrowsClientError() async {
        let (client, http) = makeClient()
        http.handler = { request in
            try TestHTTP.response(for: request, statusCode: 422)
        }

        do {
            _ = try await client.fetchPullRequests(query: "is:pr", cursor: nil)
            Issue.record("Should have thrown")
        } catch let error as GitHubClientError {
            if case .clientError(let code) = error {
                #expect(code == 422)
            } else {
                Issue.record("Expected clientError, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - HTTP 429

    @Test("throws rateLimited on HTTP 429 response")
    func http429ThrowsRateLimited() async {
        let (client, http) = makeClient()
        http.handler = { request in
            try TestHTTP.response(for: request, statusCode: 429, headers: ["Retry-After": "60"])
        }

        do {
            _ = try await client.fetchPullRequests(query: "is:pr", cursor: nil)
            Issue.record("Should have thrown")
        } catch let error as GitHubClientError {
            if case .rateLimited(let retryAfter) = error {
                #expect(retryAfter == 60)
            } else {
                Issue.record("Expected rateLimited, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - HTTP 401

    @Test("throws unauthorized on HTTP 401 and invokes onUnauthorized callback")
    func http401ThrowsUnauthorized() async {
        nonisolated(unsafe) var capturedToken: String?
        let http = MockHTTPSession()
        let client = GitHubClient(
            tokenProvider: { "test-token" },
            onUnauthorized: { token in capturedToken = token },
            session: http.urlSession
        )
        http.handler = { request in
            try TestHTTP.response(for: request, statusCode: 401)
        }

        do {
            _ = try await client.fetchPullRequests(query: "is:pr", cursor: nil)
            Issue.record("Should have thrown")
        } catch let error as GitHubClientError {
            if case .unauthorized = error {
                #expect(capturedToken == "test-token")
            } else {
                Issue.record("Expected unauthorized, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - Error descriptions

    @Test("rateLimited error has user-friendly description")
    func rateLimitedDescription() {
        let error = GitHubClientError.rateLimited(retryAfter: nil)
        #expect(error.errorDescription?.contains("rate limit") == true)
    }

    @Test("clientError includes status code")
    func clientErrorDescription() {
        let error = GitHubClientError.clientError(statusCode: 400)
        #expect(error.errorDescription?.contains("400") == true)
    }

    @Test("serverError includes status code")
    func serverErrorDescription() {
        let error = GitHubClientError.serverError(statusCode: 503)
        #expect(error.errorDescription?.contains("503") == true)
    }
}
