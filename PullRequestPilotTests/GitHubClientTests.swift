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

    @Test("throws missingToken without sending a request when the token is nil")
    func nilTokenThrowsMissingToken() async {
        let (client, http) = makeClient(token: nil)
        http.handler = { _ in
            Issue.record("Should not reach network")
            throw URLError(.badServerResponse)
        }

        let error = await #expect(throws: GitHubClientError.self) {
            _ = try await client.fetchPullRequests(query: "is:pr", cursor: nil)
        }
        guard case .missingToken? = error else {
            Issue.record("Expected missingToken, got \(String(describing: error))")
            return
        }
    }

    @Test("throws missingToken without sending a request when the token is empty")
    func emptyTokenThrowsMissingToken() async {
        let (client, http) = makeClient(token: "")
        http.handler = { _ in
            Issue.record("Should not reach network")
            throw URLError(.badServerResponse)
        }

        let error = await #expect(throws: GitHubClientError.self) {
            _ = try await client.fetchPullRequests(query: "is:pr", cursor: nil)
        }
        guard case .missingToken? = error else {
            Issue.record("Expected missingToken, got \(String(describing: error))")
            return
        }
    }

    @Test("validateToken reports a classic token's scopes")
    func validateTokenReportsClassicScopes() async throws {
        let (client, http) = makeClient()
        http.handler = { request in
            try TestHTTP.response(
                for: request,
                body: Data(#"{"data": {"viewer": {"login": "octocat", "avatarUrl": null}}}"#.utf8),
                headers: ["X-OAuth-Scopes": "public_repo, read:org"]
            )
        }

        let validation = try await client.validateToken("ghp_classic")

        #expect(validation.login == "octocat")
        #expect(validation.classicTokenScopes == ["public_repo", "read:org"])
        #expect(validation.lacksPrivateRepositoryAccess)
    }

    @Test("validateToken reports no scopes for a fine-grained token")
    func validateTokenFineGrainedHasNoScopes() async throws {
        let (client, http) = makeClient()
        http.handler = { request in
            try TestHTTP.response(for: request, body: Data(#"{"data": {"viewer": {"login": "octocat", "avatarUrl": null}}}"#.utf8))
        }

        let validation = try await client.validateToken("github_pat_fine")

        #expect(validation.classicTokenScopes == nil)
        #expect(!validation.lacksPrivateRepositoryAccess)
    }

    @Test("a classic token with the repo scope reads private repositories")
    func repoScopeCoversPrivateRepositories() {
        #expect(!TokenValidation(login: "a", avatarURL: nil, classicTokenScopes: ["repo", "workflow"]).lacksPrivateRepositoryAccess)
        #expect(TokenValidation(login: "a", avatarURL: nil, classicTokenScopes: []).lacksPrivateRepositoryAccess)
        #expect(GitHubClient.parseScopes(" repo ,read:org,, ") == ["repo", "read:org"])
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

    // MARK: - Partial results

    @Test("results withheld behind SAML come back counted, with GitHub's reason once")
    func partialErrorsReturnedWithPage() async throws {
        let (client, http) = makeClient()
        let samlMessage = "Resource protected by organization SAML enforcement. You must grant your Personal Access token access to this organization."
        let samlError = #"{"type": "FORBIDDEN", "message": "\#(samlMessage)"}"#
        let response = """
        {
            "data": {
                "search": {
                    "nodes": [null, null, \(makePullRequestNodeJSON())],
                    "pageInfo": {"hasNextPage": false, "endCursor": null}
                }
            },
            "errors": [\(samlError), \(samlError)]
        }
        """
        http.handler = { request in
            try TestHTTP.response(for: request, body: Data(response.utf8))
        }

        let page = try await client.fetchPullRequests(query: "is:pr", cursor: nil)

        #expect(page.pullRequests.map(\.id) == ["PR_1"])
        #expect(page.withheldResultCount == 2)
        #expect(page.partialErrorMessages == [samlMessage])
    }

    private static func timelineJSON(timelineCursor: String, checksCursor: String) -> String {
        """
        {"data": {"node": {
            "timelineItems": {"nodes": [], "pageInfo": {"hasNextPage": true, "endCursor": "\(timelineCursor)"}},
            "commits": {"nodes": [{"commit": {"statusCheckRollup": {"contexts": {
                "nodes": [], "pageInfo": {"hasNextPage": true, "endCursor": "\(checksCursor)"}
            }}}}]}
        }}}
        """
    }

    @Test("fetchTimeline returns the timeline and checks cursors GitHub sends")
    func fetchTimelineReturnsCursors() async throws {
        let (client, http) = makeClient()
        http.handler = { request in
            try TestHTTP.response(for: request, body: Data(Self.timelineJSON(timelineCursor: "timeline-2", checksCursor: "checks-2").utf8))
        }

        let page = try await client.fetchTimeline(nodeID: "PR_1", cursor: nil, eventPageOffset: 0, checksPageOffset: 0)

        #expect(page.nextCursor == "timeline-2")
        #expect(page.checksNextCursor == "checks-2")
    }

    @Test("fetchTimeline counts every timeline node, including those that map to no event")
    func fetchTimelineCountsAllNodes() async throws {
        let (client, http) = makeClient()
        let body = """
        {"data": {"node": {"timelineItems": {
            "nodes": [
                {"__typename": "IssueComment", "createdAt": "2024-01-15T10:00:00Z", "author": {"login": "alice", "avatarUrl": null}, "body": "hi"},
                {"__typename": "LabeledEvent", "createdAt": "2024-01-15T10:05:00Z"}
            ],
            "pageInfo": {"hasNextPage": false, "endCursor": null}
        }}}}
        """
        http.handler = { request in
            try TestHTTP.response(for: request, body: Data(body.utf8))
        }

        let page = try await client.fetchTimeline(nodeID: "PR_1", cursor: nil, eventPageOffset: 0, checksPageOffset: 0)

        #expect(page.events.count == 1)
        #expect(page.eventNodeCount == 2)
    }

    @Test("an empty-string end cursor ends timeline and checks pagination")
    func fetchTimelineEmptyCursorsAreNil() async throws {
        let (client, http) = makeClient()
        http.handler = { request in
            try TestHTTP.response(for: request, body: Data(Self.timelineJSON(timelineCursor: "", checksCursor: "").utf8))
        }

        let page = try await client.fetchTimeline(nodeID: "PR_1", cursor: nil, eventPageOffset: 0, checksPageOffset: 0)

        #expect(page.nextCursor == nil)
        #expect(page.checksNextCursor == nil)
    }

    @Test("fetchChecks returns the next cursor and treats an empty one as the end", arguments: [("checks-3", "checks-3"), ("", nil)])
    func fetchChecksCursor(endCursor: String, expected: String?) async throws {
        let (client, http) = makeClient()
        http.handler = { request in
            try TestHTTP.response(for: request, body: Data(Self.timelineJSON(timelineCursor: "unused", checksCursor: endCursor).utf8))
        }

        let page = try await client.fetchChecks(nodeID: "PR_1", cursor: "checks-2", checksPageOffset: 0)

        #expect(page.nextCursor == expected)
    }

    @Test("an empty-string search end cursor ends pagination")
    func fetchPullRequestsEmptyCursorIsNil() async throws {
        let (client, http) = makeClient()
        let responseJSON = makeSearchResponseJSON(hasNextPage: true, endCursor: "")
        http.handler = { request in
            try TestHTTP.response(for: request, body: Data(responseJSON.utf8))
        }

        let page = try await client.fetchPullRequests(query: "is:pr", cursor: nil)

        #expect(page.nextCursor == nil)
    }

    @Test("a cancelled URL session request surfaces as CancellationError, not a network error")
    func urlCancellationBecomesCancellationError() async {
        let (client, http) = makeClient()
        http.handler = { _ in throw URLError(.cancelled) }

        await #expect(throws: CancellationError.self) {
            _ = try await client.fetchPullRequests(query: "is:pr", cursor: nil)
        }
    }

    @Test("a PR that no longer resolves throws GitHub's reason instead of an empty timeline")
    func fetchTimelineNullNodeThrows() async {
        let (client, http) = makeClient()
        let body = #"{"data": {"node": null}, "errors": [{"type": "NOT_FOUND", "message": "Could not resolve to a node with the global id of 'PR_gone'"}]}"#
        http.handler = { request in
            try TestHTTP.response(for: request, body: Data(body.utf8))
        }

        do {
            _ = try await client.fetchTimeline(nodeID: "PR_gone", cursor: nil, eventPageOffset: 0, checksPageOffset: 0)
            Issue.record("Should have thrown")
        } catch GitHubClientError.graphQLErrors(let messages) {
            #expect(messages == ["Could not resolve to a node with the global id of 'PR_gone'"])
        } catch {
            Issue.record("Expected graphQLErrors, got \(error)")
        }
    }

    @Test("a null PR node without errors still reports the PR as unavailable")
    func fetchTimelineNullNodeWithoutErrorsThrows() async {
        let (client, http) = makeClient()
        http.handler = { request in
            try TestHTTP.response(for: request, body: Data(#"{"data": {"node": null}}"#.utf8))
        }

        await #expect(throws: GitHubClientError.self) {
            _ = try await client.fetchTimeline(nodeID: "PR_gone", cursor: nil, eventPageOffset: 0, checksPageOffset: 0)
        }
    }

    // MARK: - Draft State Mutation

    @Test("setDraft sends the convert mutation and accepts the draft result")
    func setDraftSendsMutation() async throws {
        let (client, http) = makeClient()
        var capturedBody = ""
        http.handler = { request in
            capturedBody = Self.bodyString(of: request)
            let responseJSON = #"{"data": {"payload": {"pullRequest": {"isDraft": true}}}}"#
            return try TestHTTP.response(for: request, body: Data(responseJSON.utf8))
        }

        try await client.setDraft(pullRequestID: "PR_42", isDraft: true)

        #expect(capturedBody.contains("convertPullRequestToDraft"))
        #expect(capturedBody.contains("PR_42"))
    }

    @Test("setDraft surfaces GitHub's refusal message")
    func setDraftRefused() async {
        let (client, http) = makeClient()
        let responseJSON = #"{"data": {"payload": null}, "errors": [{"type": "FORBIDDEN", "message": "Resource not accessible by personal access token"}]}"#
        http.handler = { request in
            try TestHTTP.response(for: request, body: Data(responseJSON.utf8))
        }

        do {
            try await client.setDraft(pullRequestID: "PR_42", isDraft: false)
            Issue.record("Should have thrown")
        } catch GitHubClientError.graphQLErrors(let messages) {
            #expect(messages == ["Resource not accessible by personal access token"])
        } catch {
            Issue.record("Expected graphQLErrors, got \(error)")
        }
    }

    @Test("setDraft throws when GitHub reports a different draft state")
    func setDraftStateMismatch() async {
        let (client, http) = makeClient()
        let responseJSON = #"{"data": {"payload": {"pullRequest": {"isDraft": false}}}}"#
        http.handler = { request in
            try TestHTTP.response(for: request, body: Data(responseJSON.utf8))
        }

        await #expect(throws: GitHubClientError.self) {
            try await client.setDraft(pullRequestID: "PR_42", isDraft: true)
        }
    }

    // MARK: - GitHubClientError descriptions

    @Test("error descriptions are user-friendly")
    func errorDescriptions() {
        #expect(GitHubClientError.unauthorized.errorDescription?.contains("token") == true)
        #expect(GitHubClientError.graphQLErrors(["test"]).errorDescription?.contains("test") == true)
        #expect(GitHubClientError.networkError(URLError(.notConnectedToInternet)).errorDescription?.contains("Network") == true)
        let decodingError = GitHubClientError.decodingError(URLError(.cannotParseResponse))
        #expect(decodingError.errorDescription == decodingError.asAppError.errorDescription)
    }

    // MARK: - Helpers

    /// URLProtocol receives POST bodies as a stream, not `httpBody`.
    private static func bodyString(of request: URLRequest) -> String {
        if let body = request.httpBody { return String(bytes: body, encoding: .utf8) ?? "" }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    private func makePullRequestNodeJSON() -> String {
        """
        {
            "__typename": "PullRequest",
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
            "commits": {"nodes": []},
            "baseRefName": "main",
            "headRefName": "feature",
            "headRefOid": "sha123",
            "isCrossRepository": false,
            "repository": {"nameWithOwner": "owner/repo"},
            "author": {"__typename": "User", "login": "dev", "avatarUrl": null},
            "reviewThreads": {"totalCount": 0, "nodes": []},
            "latestReviews": {"nodes": []},
            "labels": {"nodes": []},
            "timelineItems": {"nodes": []}
        }
        """
    }

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
