import Testing
import Foundation
@testable import PullRequestPilot

@Suite("GitHubClient HTTP Error Handling", .serialized)
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
