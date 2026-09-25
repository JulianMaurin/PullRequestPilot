import Foundation
import os

// MARK: - Protocol

struct PullRequestPage: Sendable {
    let pullRequests: [PullRequest]
    let nextCursor: String?
    /// Issues or discussions the query matched; only pull requests are listed.
    let nonPullRequestCount: Int
    /// Matches GitHub withheld (e.g. SAML SSO); `partialErrorMessages` says why.
    let withheldResultCount: Int
    let undecodablePullRequestCount: Int
    /// GitHub's messages for errors returned alongside data, de-duplicated.
    let partialErrorMessages: [String]

    init(
        pullRequests: [PullRequest],
        nextCursor: String?,
        nonPullRequestCount: Int = 0,
        withheldResultCount: Int = 0,
        undecodablePullRequestCount: Int = 0,
        partialErrorMessages: [String] = []
    ) {
        self.pullRequests = pullRequests
        self.nextCursor = nextCursor
        self.nonPullRequestCount = nonPullRequestCount
        self.withheldResultCount = withheldResultCount
        self.undecodablePullRequestCount = undecodablePullRequestCount
        self.partialErrorMessages = partialErrorMessages
    }
}

struct TimelinePage: Sendable {
    let events: [TimelineEvent]
    let checkRuns: [CheckRun]
    let reviewers: [Reviewer]
    let nextCursor: String?
    let checksNextCursor: String?
    /// Timeline nodes on the page, including those that map to no event.
    /// Event IDs embed the node's index, so the next page's indexes start
    /// after all of them.
    let eventNodeCount: Int

    init(events: [TimelineEvent], checkRuns: [CheckRun], reviewers: [Reviewer], nextCursor: String?, checksNextCursor: String?, eventNodeCount: Int? = nil) {
        self.events = events
        self.checkRuns = checkRuns
        self.reviewers = reviewers
        self.nextCursor = nextCursor
        self.checksNextCursor = checksNextCursor
        self.eventNodeCount = eventNodeCount ?? events.count
    }
}

struct ChecksPage: Sendable {
    let checkRuns: [CheckRun]
    let nextCursor: String?
}

/// The account a token belongs to, and what it may read.
struct TokenValidation: Sendable, Equatable {
    let login: String
    let avatarURL: URL?
    /// A classic token's scopes (`X-OAuth-Scopes`); nil for fine-grained
    /// tokens, which don't report scopes.
    let classicTokenScopes: Set<String>?

    init(login: String, avatarURL: URL?, classicTokenScopes: Set<String>? = nil) {
        self.login = login
        self.avatarURL = avatarURL
        self.classicTokenScopes = classicTokenScopes
    }

    /// A classic token without `repo` validates, but private repositories'
    /// pull requests never appear in its searches.
    var lacksPrivateRepositoryAccess: Bool {
        guard let classicTokenScopes else { return false }
        return !classicTokenScopes.contains("repo")
    }
}

protocol GitHubClientProtocol: Sendable {
    func fetchPullRequests(query: String, cursor: String?, pageSize: Int) async throws -> PullRequestPage
    func fetchTimeline(nodeID: String, cursor: String?, eventPageOffset: Int, checksPageOffset: Int) async throws -> TimelinePage
    func fetchChecks(nodeID: String, cursor: String, checksPageOffset: Int) async throws -> ChecksPage
    func fetchViewer() async throws -> (login: String, avatarURL: URL?)
    /// Validates an explicit token against the GitHub API, bypassing the
    /// ambient token provider. Used by IdentityActor.swap before committing.
    func validateToken(_ token: String) async throws -> TokenValidation
    /// Converts an open pull request to draft, or marks a draft ready for review.
    /// Throws unless GitHub reports the requested state afterwards.
    func setDraft(pullRequestID: String, isDraft: Bool) async throws
}

extension GitHubClientProtocol {
    func fetchPullRequests(query: String, cursor: String?) async throws -> PullRequestPage {
        try await fetchPullRequests(query: query, cursor: cursor, pageSize: Constants.App.searchPageSize)
    }
}

// MARK: - Errors

enum GitHubClientError: LocalizedError {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case permissionDenied(detail: String?)
    case clientError(statusCode: Int)
    case serverError(statusCode: Int)
    case graphQLErrors([String])
    case networkError(Error)
    case decodingError(Error)

    /// `AppError` owns the wording, so the inline error and the toast for
    /// one failure always read the same.
    var errorDescription: String? {
        asAppError.errorDescription
    }

    /// Map this typed error to the app-wide `AppError` surface.
    var asAppError: AppError {
        switch self {
        case .unauthorized:
            return .unauthorized
        case .rateLimited(let retryAfter):
            let resetAt = retryAfter.map { Date(timeIntervalSinceNow: $0) }
            return .rateLimited(resetAt: resetAt)
        case .permissionDenied(let detail):
            return .permissionDenied(detail: detail)
        case .clientError(let code):
            return .requestRejected(statusCode: code)
        case .serverError(let code):
            return .serverError(statusCode: code)
        case .graphQLErrors(let messages):
            return .graphQLErrors(messages)
        case .networkError(let underlying):
            return .network(underlying: underlying.localizedDescription)
        case .decodingError(let underlying):
            return .decodeResponse(detail: underlying.localizedDescription)
        }
    }

    /// True when the underlying cause is offline / connectivity. Used to pick
    /// a dedicated empty-state UI ("No connection") instead of a generic error.
    var isNetworkFailure: Bool {
        switch self {
        case .networkError: return true
        default: return false
        }
    }
}

// MARK: - Error helpers

extension Error {
    /// The user-facing form of any failure the app's layers throw.
    var asAppError: AppError {
        if let clientError = self as? GitHubClientError {
            return clientError.asAppError
        }
        if let appError = self as? AppError {
            return appError
        }
        return .network(underlying: localizedDescription)
    }

    /// Generic network-failure detector for any `Error` — handles typed client
    /// errors and raw `URLError` codes alike. Replaces the old
    /// `ErrorNetworkCheck` extension that lived alongside the classifier.
    var isNetworkError: Bool {
        if let clientError = self as? GitHubClientError { return clientError.isNetworkFailure }
        if let appError = self as? AppError { return appError.isNetworkFailure }
        if let urlError = self as? URLError,
           [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
            .cannotConnectToHost, .dnsLookupFailed].contains(urlError.code) {
            return true
        }
        return false
    }
}

// MARK: - Implementation

final class GitHubClient: GitHubClientProtocol, Sendable {
    private let tokenProvider: @Sendable () async -> String?
    private let onUnauthorized: @Sendable (String) -> Void
    private let session: URLSession
    private let logger = Logger(category: "GitHubClient")

    /// Coalesces concurrent identical reads (same query + token) into a single
    /// network round-trip. Two dashboard views polling the same repo, or two
    /// `refreshAll` calls overlapping, now share one request instead of racing.
    private let networkCoalescer = RequestCoalescer<NetworkKey, RawResponse>()

    private struct NetworkKey: Hashable, Sendable {
        let query: String
        let token: String
    }

    private static let endpoint: URL =
        URL(string: "https://api.github.com/graphql")
        ?? URL(fileURLWithPath: "/")

    private static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    init(tokenProvider: @escaping @Sendable () async -> String?, onUnauthorized: @escaping @Sendable (String) -> Void = { _ in }, session: URLSession? = nil) {
        self.tokenProvider = tokenProvider
        self.onUnauthorized = onUnauthorized
        self.session = session ?? Self.defaultSession
    }

    func fetchPullRequests(query searchQuery: String, cursor: String?, pageSize: Int) async throws -> PullRequestPage {
        let query = GitHubGraphQL.searchQuery(query: searchQuery, cursor: cursor, pageSize: pageSize)
        let response: GraphQLResponse<SearchData> = try await execute(query: query)

        if let errors = response.errors, !errors.isEmpty, response.data != nil {
            logger.warning("GraphQL partial errors: \(errors.map(\.message).joined(separator: "; "), privacy: .public)")
        }

        guard let data = response.data else {
            let messages = response.errors?.map(\.message) ?? ["Unknown error"]
            throw GitHubClientError.graphQLErrors(messages)
        }

        let search = data.search
        let prs = search.nodes.compactMap { $0.toDomain() }
        if search.undecodablePullRequestCount > 0 || search.withheldResultCount > 0 {
            logger.warning("Search hid \(search.withheldResultCount, privacy: .public) withheld and \(search.undecodablePullRequestCount, privacy: .public) undecodable pull request(s)")
        }
        logger.info("Page returned \(search.nodes.count, privacy: .public) node(s), mapped \(prs.count, privacy: .public) PR(s)")

        let rawCursor = search.pageInfo.hasNextPage ? search.pageInfo.endCursor : nil
        let nextCursor = rawCursor?.isEmpty == false ? rawCursor : nil
        var seenMessages = Set<String>()
        let partialErrorMessages = (response.errors ?? []).map(\.message).filter { seenMessages.insert($0).inserted }
        return PullRequestPage(
            pullRequests: prs,
            nextCursor: nextCursor,
            nonPullRequestCount: search.nonPullRequestCount,
            withheldResultCount: search.withheldResultCount,
            undecodablePullRequestCount: search.undecodablePullRequestCount,
            partialErrorMessages: partialErrorMessages
        )
    }

    func fetchTimeline(nodeID: String, cursor: String? = nil, eventPageOffset: Int = 0, checksPageOffset: Int = 0) async throws -> TimelinePage {
        let query = GitHubGraphQL.timelineQuery(nodeID: nodeID, cursor: cursor)
        let response: GraphQLResponse<TimelineNodeData> = try await execute(query: query)

        if let errors = response.errors, !errors.isEmpty, response.data != nil {
            logger.warning("GraphQL partial errors: \(errors.map(\.message).joined(separator: "; "), privacy: .public)")
        }

        guard let data = response.data else {
            let messages = response.errors?.map(\.message) ?? ["Unknown error"]
            throw GitHubClientError.graphQLErrors(messages)
        }

        guard let prNode = data.node else {
            throw Self.unavailablePullRequestError(response.errors)
        }

        let events = prNode.timelineItems?.toDomain(pageOffset: eventPageOffset) ?? []
        let checkRuns = prNode.commits?.toDomain(pageOffset: checksPageOffset) ?? []
        let reviewers = prNode.toReviewers()
        let rawTimelineCursor = prNode.timelineItems?.pageInfo.hasNextPage == true
            ? prNode.timelineItems?.pageInfo.endCursor : nil
        let nextCursor = rawTimelineCursor?.isEmpty == false ? rawTimelineCursor : nil
        let checksPageInfo = prNode.commits?.nodes.first?.commit.statusCheckRollup?.contexts.pageInfo
        let rawChecksCursor = checksPageInfo?.hasNextPage == true ? checksPageInfo?.endCursor : nil
        let checksNextCursor = rawChecksCursor?.isEmpty == false ? rawChecksCursor : nil
        return TimelinePage(
            events: events,
            checkRuns: checkRuns,
            reviewers: reviewers,
            nextCursor: nextCursor,
            checksNextCursor: checksNextCursor,
            eventNodeCount: prNode.timelineItems?.nodes.count ?? 0
        )
    }

    func fetchChecks(nodeID: String, cursor: String, checksPageOffset: Int = 0) async throws -> ChecksPage {
        let query = GitHubGraphQL.checksQuery(nodeID: nodeID, cursor: cursor)
        let response: GraphQLResponse<TimelineNodeData> = try await execute(query: query)

        if let errors = response.errors, !errors.isEmpty, response.data != nil {
            logger.warning("GraphQL partial errors: \(errors.map(\.message).joined(separator: "; "), privacy: .public)")
        }

        guard let data = response.data else {
            let messages = response.errors?.map(\.message) ?? ["Unknown error"]
            throw GitHubClientError.graphQLErrors(messages)
        }

        guard let prNode = data.node else {
            throw Self.unavailablePullRequestError(response.errors)
        }
        let checkRuns = prNode.commits?.toDomain(pageOffset: checksPageOffset) ?? []
        let pageInfo = prNode.commits?.nodes.first?.commit.statusCheckRollup?.contexts.pageInfo
        let rawCheckCursor = pageInfo?.hasNextPage == true ? pageInfo?.endCursor : nil
        let nextCursor = rawCheckCursor?.isEmpty == false ? rawCheckCursor : nil
        return ChecksPage(checkRuns: checkRuns, nextCursor: nextCursor)
    }

    func fetchViewer() async throws -> (login: String, avatarURL: URL?) {
        let response: GraphQLResponse<ViewerData> = try await execute(query: GitHubGraphQL.viewerQuery)
        return try viewerResult(from: response)
    }

    func validateToken(_ token: String) async throws -> TokenValidation {
        let raw = try await fetchRawResponse(query: GitHubGraphQL.viewerQuery, token: token)
        let response: GraphQLResponse<ViewerData> = try decode(raw.body)
        let viewer = try viewerResult(from: response)
        return TokenValidation(
            login: viewer.login,
            avatarURL: viewer.avatarURL,
            classicTokenScopes: raw.oauthScopes.map(Self.parseScopes)
        )
    }

    /// `X-OAuth-Scopes` lists scopes separated by commas and spaces.
    static func parseScopes(_ header: String) -> Set<String> {
        Set(header.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    func setDraft(pullRequestID: String, isDraft: Bool) async throws {
        // Both mutations are idempotent, so sharing the coalesced request path is safe.
        let mutation = GitHubGraphQL.setDraftMutation(pullRequestID: pullRequestID, isDraft: isDraft)
        let response: GraphQLResponse<DraftStateMutationData> = try await execute(query: mutation)

        if let errors = response.errors, !errors.isEmpty {
            throw GitHubClientError.graphQLErrors(errors.map(\.message))
        }
        guard response.data?.payload?.pullRequest?.isDraft == isDraft else {
            throw GitHubClientError.graphQLErrors(["GitHub didn't apply the draft-state change."])
        }
    }

    // MARK: - Private

    /// `node: null`: the PR was deleted, transferred, or the token lost access
    /// (SAML SSO included). GitHub's own messages name the cause when present.
    private static func unavailablePullRequestError(_ errors: [GraphQLError]?) -> GitHubClientError {
        let messages = (errors ?? []).map(\.message)
        return .graphQLErrors(messages.isEmpty ? ["This pull request is no longer available."] : messages)
    }

    private func viewerResult(from response: GraphQLResponse<ViewerData>) throws -> (login: String, avatarURL: URL?) {
        if let errors = response.errors, !errors.isEmpty, response.data != nil {
            logger.warning("GraphQL partial errors: \(errors.map(\.message).joined(separator: "; "), privacy: .public)")
        }

        guard let data = response.data else {
            let messages = response.errors?.map(\.message) ?? ["Unknown error"]
            throw GitHubClientError.graphQLErrors(messages)
        }

        let avatarURL = data.viewer.avatarUrl.flatMap { URL(string: $0) }
        return (login: data.viewer.login, avatarURL: avatarURL)
    }

    private func execute<T: Decodable>(query: String, overrideToken: String? = nil) async throws -> GraphQLResponse<T> {
        let resolvedToken: String?
        if let overrideToken {
            resolvedToken = overrideToken
        } else {
            resolvedToken = await tokenProvider()
        }
        guard let token = resolvedToken, !token.isEmpty else {
            throw GitHubClientError.unauthorized
        }

        let raw = try await fetchRawResponse(query: query, token: token)
        return try decode(raw.body)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> GraphQLResponse<T> {
        do {
            return try JSONDecoder().decode(GraphQLResponse<T>.self, from: data)
        } catch {
            // The full response failed to decode — try to extract GraphQL errors
            if let errorOnly = try? JSONDecoder().decode(GraphQLErrorResponse.self, from: data),
               let errors = errorOnly.errors, !errors.isEmpty
            {
                throw GitHubClientError.graphQLErrors(errors.map(\.message))
            }
            throw GitHubClientError.decodingError(error)
        }
    }

    private struct RawResponse: Sendable {
        let body: Data
        let oauthScopes: String?
    }

    /// Performs the network round-trip and HTTP status classification, returning
    /// the raw response. Coalesced on (query, token): concurrent callers with
    /// the same key share a single request, decode independently.
    private func fetchRawResponse(query: String, token: String) async throws -> RawResponse {
        let key = NetworkKey(query: query, token: token)
        let session = self.session
        let onUnauthorized = self.onUnauthorized
        return try await networkCoalescer.run(key: key) {
            var request = URLRequest(url: Self.endpoint)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let urlError as URLError where urlError.code == .cancelled {
                throw CancellationError()
            } catch {
                throw GitHubClientError.networkError(error)
            }

            if let httpResponse = response as? HTTPURLResponse {
                switch httpResponse.statusCode {
                case 200...299:
                    // GitHub reports the GraphQL rate limits as HTTP 200 with
                    // an error body, not as a 403/429.
                    if Self.isGraphQLRateLimited(response: httpResponse, body: data) {
                        throw GitHubClientError.rateLimited(retryAfter: Self.rateLimitWait(from: httpResponse))
                    }
                case 401:
                    onUnauthorized(token)
                    throw GitHubClientError.unauthorized
                case 403:
                    // A 403 is a rate limit only when the headers or the message
                    // say so; otherwise it's a permission/scope error.
                    let message = Self.extractErrorMessage(from: data)
                    if Self.isRateLimited(response: httpResponse) || Self.mentionsRateLimit(message) {
                        throw GitHubClientError.rateLimited(retryAfter: Self.rateLimitWait(from: httpResponse))
                    }
                    throw GitHubClientError.permissionDenied(detail: message)
                case 429:
                    throw GitHubClientError.rateLimited(retryAfter: Self.rateLimitWait(from: httpResponse))
                case 400...499:
                    throw GitHubClientError.clientError(statusCode: httpResponse.statusCode)
                case 500...599:
                    throw GitHubClientError.serverError(statusCode: httpResponse.statusCode)
                default:
                    break
                }
            }

            let oauthScopes = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-OAuth-Scopes")
            return RawResponse(body: data, oauthScopes: oauthScopes)
        }
    }

    // MARK: - Retry-After Parsing

    private static let retryAfterLock = NSLock()
    private static let retryAfterFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    static func isRateLimited(response: HTTPURLResponse) -> Bool {
        if response.value(forHTTPHeaderField: "Retry-After") != nil { return true }
        if let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
           let remainingInt = Int(remaining), remainingInt == 0 {
            return true
        }
        return false
    }

    /// A 200 carrying GraphQL errors is rate-limited when GitHub types it
    /// `RATE_LIMITED`, the message says so (secondary limits), or the quota
    /// header reads zero. Bodies without an `errors` key skip the decode.
    static func isGraphQLRateLimited(response: HTTPURLResponse, body: Data) -> Bool {
        guard body.range(of: Data(#""errors""#.utf8)) != nil,
              let errors = try? JSONDecoder().decode(GraphQLErrorResponse.self, from: body).errors,
              !errors.isEmpty
        else { return false }
        if errors.contains(where: { $0.type == "RATE_LIMITED" || mentionsRateLimit($0.message) }) {
            return true
        }
        return response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
    }

    static func mentionsRateLimit(_ message: String?) -> Bool {
        message?.localizedCaseInsensitiveContains("rate limit") == true
    }

    /// GitHub's guidance: honor Retry-After, else wait for the quota reset,
    /// else wait at least a minute.
    static func rateLimitWait(from response: HTTPURLResponse) -> TimeInterval {
        parseRetryAfter(from: response) ?? 60
    }

    static func extractErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let message = json["message"] as? String, !message.isEmpty { return message }
        return nil
    }

    static func parseRetryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        if let retryStr = response.value(forHTTPHeaderField: "Retry-After") {
            // Try seconds first (most common for GitHub)
            if let seconds = TimeInterval(retryStr) {
                return seconds
            }
            // Try HTTP-date format (e.g. "Fri, 22 Apr 2026 12:00:00 GMT")
            retryAfterLock.lock()
            let date = retryAfterFormatter.date(from: retryStr)
            retryAfterLock.unlock()
            if let date {
                return max(0, date.timeIntervalSince1970 - Date().timeIntervalSince1970)
            }
        }
        // Fall back to X-RateLimit-Reset (UNIX timestamp)
        if let resetStr = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
           let resetTimestamp = TimeInterval(resetStr) {
            return max(0, resetTimestamp - Date().timeIntervalSince1970)
        }
        return nil
    }
}
