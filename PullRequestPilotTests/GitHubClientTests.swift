import Testing
import Foundation
@testable import PullRequestPilot

@Suite("GitHubClient")
struct GitHubClientTests {

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeClient(token: String? = "valid-token") -> GitHubClient {
        GitHubClient(tokenProvider: { token }, session: makeSession())
    }

    // MARK: - Token Validation

    @Test("throws unauthorized when token is nil")
    func nilTokenThrowsUnauthorized() async {
        let client = makeClient(token: nil)
        MockURLProtocol.requestHandler = { _ in
            Issue.record("Should not reach network")
            throw URLError(.badServerResponse)
        }

        await #expect(throws: GitHubClientError.self) {
            _ = try await client.fetchPullRequests(query: "is:pr", cursor: nil)
        }
    }

    @Test("throws unauthorized when token is empty")
    func emptyTokenThrowsUnauthorized() async {
        let client = makeClient(token: "")
        MockURLProtocol.requestHandler = { _ in
            Issue.record("Should not reach network")
            throw URLError(.badServerResponse)
        }

        await #expect(throws: GitHubClientError.self) {
            _ = try await client.fetchPullRequests(query: "is:pr", cursor: nil)
        }
    }

    // MARK: - HTTP 401

    @Test("throws unauthorized on HTTP 401 response")
    func http401ThrowsUnauthorized() async {
        let client = makeClient()
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        await #expect(throws: GitHubClientError.self) {
            _ = try await client.fetchPullRequests(query: "is:pr", cursor: nil)
        }
    }

    // MARK: - GraphQL Errors

    @Test("throws graphQLErrors when response has no data")
    func graphQLErrorsThrown() async {
        let client = makeClient()
        let responseJSON = #"{"data": null, "errors": [{"message": "Field error"}]}"#
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, responseJSON.data(using: .utf8)!)
        }

        do {
            _ = try await client.fetchPullRequests(query: "is:pr", cursor: nil)
            Issue.record("Should have thrown")
        } catch let error as GitHubClientError {
            if case .graphQLErrors(let messages) = error {
                #expect(messages.contains("Field error"))
            } else {
                Issue.record("Expected graphQLErrors, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - Successful Response

    @Test("fetchPullRequests returns mapped PRs from valid response")
    func fetchPullRequestsSuccess() async throws {
        let client = makeClient()
        let responseJSON = makeSearchResponseJSON()
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, responseJSON.data(using: .utf8)!)
        }

        let page = try await client.fetchPullRequests(query: "is:pr", cursor: nil)
        #expect(page.pullRequests.count == 1)
        #expect(page.pullRequests.first?.title == "Test PR")
        #expect(page.nextCursor == nil)
    }

    @Test("fetchPullRequests returns nextCursor when hasNextPage")
    func fetchPullRequestsWithPagination() async throws {
        let client = makeClient()
        let responseJSON = makeSearchResponseJSON(hasNextPage: true, endCursor: "cursor_abc")
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, responseJSON.data(using: .utf8)!)
        }

        let page = try await client.fetchPullRequests(query: "is:pr", cursor: nil)
        #expect(page.nextCursor != nil)
        #expect(page.nextCursor == "cursor_abc")
    }

    // MARK: - fetchViewer

    @Test("fetchViewer returns login and avatar on success")
    func fetchViewerSuccess() async throws {
        let client = makeClient()
        let responseJSON = #"{"data": {"viewer": {"login": "octocat", "avatarUrl": "https://avatars.githubusercontent.com/u/1?v=4"}}}"#
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, responseJSON.data(using: .utf8)!)
        }

        let viewer = try await client.fetchViewer()
        #expect(viewer.login == "octocat")
        #expect(viewer.avatarURL?.absoluteString == "https://avatars.githubusercontent.com/u/1?v=4")
    }

    @Test("fetchViewer throws on GraphQL errors")
    func fetchViewerGraphQLError() async {
        let client = makeClient()
        let responseJSON = #"{"data": null, "errors": [{"message": "Bad credentials"}]}"#
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, responseJSON.data(using: .utf8)!)
        }

        await #expect(throws: GitHubClientError.self) {
            _ = try await client.fetchViewer()
        }
    }

    // MARK: - Network Error

    @Test("wraps network errors in GitHubClientError.networkError")
    func networkErrorWrapped() async {
        let client = makeClient()
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        do {
            _ = try await client.fetchPullRequests(query: "is:pr", cursor: nil)
            Issue.record("Should have thrown")
        } catch let error as GitHubClientError {
            if case .networkError = error {
                // expected
            } else {
                Issue.record("Expected networkError, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - Decoding Error

    @Test("wraps decoding errors in GitHubClientError.decodingError")
    func decodingErrorWrapped() async {
        let client = makeClient()
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "not json".data(using: .utf8)!)
        }

        do {
            _ = try await client.fetchPullRequests(query: "is:pr", cursor: nil)
            Issue.record("Should have thrown")
        } catch let error as GitHubClientError {
            if case .decodingError = error {
                // expected
            } else {
                Issue.record("Expected decodingError, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - Request Construction

    @Test("sends Authorization header with bearer token")
    func authorizationHeader() async throws {
        let client = makeClient(token: "my-secret-token")
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let responseJSON = #"{"data": {"viewer": {"login": "test"}}}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, responseJSON.data(using: .utf8)!)
        }

        _ = try await client.fetchViewer()
        #expect(capturedRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer my-secret-token")
        #expect(capturedRequest?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(capturedRequest?.httpMethod == "POST")
    }

    // MARK: - GitHubClientError descriptions

    @Test("error descriptions are user-friendly")
    func errorDescriptions() {
        #expect(GitHubClientError.unauthorized.errorDescription?.contains("token") == true)
        #expect(GitHubClientError.graphQLErrors(["test"]).errorDescription?.contains("test") == true)
        #expect(GitHubClientError.networkError(URLError(.notConnectedToInternet)).errorDescription?.contains("Network") == true)
        #expect(GitHubClientError.decodingError(URLError(.cannotParseResponse)).errorDescription?.contains("query") == true)
    }

    // MARK: - Helpers

    private func makeSearchResponseJSON(hasNextPage: Bool = false, endCursor: String? = nil) -> String {
        let endCursorVal = endCursor.map { #""\#($0)""# } ?? "null"
        return """
        {
            "data": {
                "search": {
                    "nodes": [{
                        "id": "PR_1",
                        "number": 1,
                        "title": "Test PR",
                        "url": "https://github.com/owner/repo/pull/1",
                        "createdAt": "2024-01-15T10:30:00.000Z",
                        "updatedAt": "2024-01-16T14:00:00.000Z",
                        "additions": 5,
                        "deletions": 2,
                        "state": "OPEN",
                        "isDraft": false,
                        "reviewDecision": "REVIEW_REQUIRED",
                        "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "SUCCESS"}}}]},
                        "baseRefName": "main",
                        "headRefName": "feature",
                        "headRefOid": "sha123",
                        "repository": {"nameWithOwner": "owner/repo"},
                        "author": {"login": "dev", "avatarUrl": null},
                        "reviewThreads": {"totalCount": 0, "nodes": []},
                        "latestReviews": {"nodes": []},
                        "labels": {"nodes": []},
                        "timelineItems": {"nodes": []}
                    }],
                    "pageInfo": {
                        "hasNextPage": \(hasNextPage),
                        "endCursor": \(endCursorVal)
                    }
                }
            }
        }
        """
    }

    // MARK: - isNetworkError

    @Test("isNetworkError returns true for GitHubClientError.networkError")
    func networkErrorDetected() {
        let error: Error = GitHubClientError.networkError(URLError(.notConnectedToInternet))
        #expect(error.isNetworkError)
    }

    @Test("isNetworkError returns true for URLError offline codes")
    func urlErrorOfflineDetected() {
        let codes: [URLError.Code] = [
            .notConnectedToInternet, .networkConnectionLost, .timedOut,
            .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
        ]
        for code in codes {
            let error: Error = URLError(code)
            #expect(error.isNetworkError, "Expected true for URLError code \(code.rawValue)")
        }
    }

    @Test("isNetworkError returns false for non-network errors")
    func nonNetworkErrorReturnsFalse() {
        let error: Error = GitHubClientError.unauthorized
        #expect(!error.isNetworkError)
    }
}
