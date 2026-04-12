import Testing
import Foundation
@testable import PullRequestPilot

@Suite("GitHubClient HTTP Error Handling")
struct GitHubClientHTTPErrorTests {

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeClient(token: String = "valid-token") -> GitHubClient {
        GitHubClient(tokenProvider: { token }, session: makeSession())
    }

    // MARK: - HTTP 403

    @Test("throws rateLimited on HTTP 403 response")
    func http403ThrowsRateLimited() async {
        let client = makeClient()
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 403,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        do {
            _ = try await client.fetchPullRequests(query: "is:pr", cursor: nil)
            Issue.record("Should have thrown")
        } catch let error as GitHubClientError {
            if case .rateLimited = error {
                // expected
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
        let client = makeClient()
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
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
        let client = makeClient()
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 502,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
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
        let client = makeClient()
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 400,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
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
        let client = makeClient()
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 422,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
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
        let client = makeClient()
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "60"]
            )!
            return (response, Data())
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
        let client = GitHubClient(
            tokenProvider: { "test-token" },
            onUnauthorized: { token in capturedToken = token },
            session: makeSession()
        )
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
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
