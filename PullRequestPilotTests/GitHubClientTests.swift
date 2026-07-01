import Testing
import Foundation
@testable import PullRequestPilot

@Suite("GitHubClient", .serialized)
struct GitHubClientTests {

    private func makeClient(token: String? = "valid-token") -> (client: GitHubClient, http: MockHTTPSession) {
        let http = MockHTTPSession()
        return (GitHubClient(tokenProvider: { token }, session: http.urlSession), http)
    }

    // MARK: - Token Validation

    @Test("throws unauthorized when token is nil")
    func nilTokenThrowsUnauthorized() async {
        let (client, http) = makeClient(token: nil)
        http.handler = { _ in
            Issue.record("Should not reach network")
            throw URLError(.badServerResponse)
        }

        await #expect(throws: GitHubClientError.self) {
            _ = try await client.fetchPullRequests(query: "is:pr", cursor: nil)
        }
    }

    @Test("throws unauthorized when token is empty")
    func emptyTokenThrowsUnauthorized() async {
        let (client, http) = makeClient(token: "")
        http.handler = { _ in
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
        let (client, http) = makeClient()
        http.handler = { request in
            try TestHTTP.response(for: request, statusCode: 401)
        }

        await #expect(throws: GitHubClientError.self) {
            _ = try await client.fetchPullRequests(query: "is:pr", cursor: nil)
        }
    }

    // MARK: - GraphQL Errors

    @Test("throws graphQLErrors when response has no data")
    func graphQLErrorsThrown() async {
        let (client, http) = makeClient()
        let responseJSON = #"{"data": null, "errors": [{"message": "Field error"}]}"#
        http.handler = { request in
            try TestHTTP.response(for: request, body: Data(responseJSON.utf8))
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
        let (client, http) = makeClient()
        let responseJSON = makeSearchResponseJSON()
        http.handler = { request in
            try TestHTTP.response(for: request, body: Data(responseJSON.utf8))
        }

        let page = try await client.fetchPullRequests(query: "is:pr", cursor: nil)
        #expect(page.pullRequests.count == 1)
        #expect(page.pullRequests.first?.title == "Test PR")
        #expect(page.nextCursor == nil)
    }

    @Test("fetchPullRequests returns nextCursor when hasNextPage")
    func fetchPullRequestsWithPagination() async throws {
        let (client, http) = makeClient()
        let responseJSON = makeSearchResponseJSON(hasNextPage: true, endCursor: "cursor_abc")
        http.handler = { request in
            try TestHTTP.response(for: request, body: Data(responseJSON.utf8))
        }

        let page = try await client.fetchPullRequests(query: "is:pr", cursor: nil)
        #expect(page.nextCursor != nil)
        #expect(page.nextCursor == "cursor_abc")
    }

    // MARK: - fetchViewer

    @Test("fetchViewer returns login and avatar on success")
    func fetchViewerSuccess() async throws {
        let (client, http) = makeClient()
        let responseJSON = #"{"data": {"viewer": {"login": "octocat", "avatarUrl": "https://avatars.githubusercontent.com/u/1?v=4"}}}"#
        http.handler = { request in
            try TestHTTP.response(for: request, body: Data(responseJSON.utf8))
        }

        let viewer = try await client.fetchViewer()
        #expect(viewer.login == "octocat")
        #expect(viewer.avatarURL?.absoluteString == "https://avatars.githubusercontent.com/u/1?v=4")
    }

    @Test("fetchViewer throws on GraphQL errors")
    func fetchViewerGraphQLError() async {
        let (client, http) = makeClient()
        let responseJSON = #"{"data": null, "errors": [{"message": "Bad credentials"}]}"#
        http.handler = { request in
            try TestHTTP.response(for: request, body: Data(responseJSON.utf8))
        }

        await #expect(throws: GitHubClientError.self) {
            _ = try await client.fetchViewer()
        }
    }

    // MARK: - Network Error

    @Test("wraps network errors in GitHubClientError.networkError")
    func networkErrorWrapped() async {
        let (client, http) = makeClient()
        http.handler = { _ in
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
        let (client, http) = makeClient()
        http.handler = { request in
            try TestHTTP.response(for: request, body: Data("not json".utf8))
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
        let (client, http) = makeClient(token: "my-secret-token")
        var capturedRequest: URLRequest?
        http.handler = { request in
            capturedRequest = request
            let responseJSON = #"{"data": {"viewer": {"login": "test"}}}"#
            return try TestHTTP.response(for: request, body: Data(responseJSON.utf8))
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

    // MARK: - Per-session handler routing

    @Test("concurrent mock sessions serve requests from their own handlers")
    func perSessionHandlerRouting() async throws {
        let first = MockHTTPSession()
        let second = MockHTTPSession()
        first.handler = { request in
            try TestHTTP.response(for: request, body: Data("first".utf8))
        }
        second.handler = { request in
            try TestHTTP.response(for: request, body: Data("second".utf8))
        }

        let url = try #require(URL(string: "https://example.com/routing"))
        async let firstResponse = first.urlSession.data(from: url)
        async let secondResponse = second.urlSession.data(from: url)
        let ((firstBody, _), (secondBody, _)) = try await (firstResponse, secondResponse)

        #expect(firstBody == Data("first".utf8))
        #expect(secondBody == Data("second".utf8))
    }
}
