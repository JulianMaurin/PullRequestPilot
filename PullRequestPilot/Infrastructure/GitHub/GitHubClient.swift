import Foundation
import os

// MARK: - Protocol

struct PullRequestPage: Sendable {
    let pullRequests: [PullRequest]
    let nextCursor: String?
    let skippedNodeCount: Int
}

struct TimelinePage: Sendable {
    let events: [TimelineEvent]
    let checkRuns: [CheckRun]
    let reviewers: [Reviewer]
    let nextCursor: String?
    let checksNextCursor: String?
}

struct ChecksPage: Sendable {
    let checkRuns: [CheckRun]
    let nextCursor: String?
}

protocol GitHubClientProtocol: Sendable {
    func fetchPullRequests(query: String, cursor: String?) async throws -> PullRequestPage
    func fetchTimeline(nodeID: String, cursor: String?, eventPageOffset: Int, checksPageOffset: Int) async throws -> TimelinePage
    func fetchChecks(nodeID: String, cursor: String, checksPageOffset: Int) async throws -> ChecksPage
    func fetchViewer() async throws -> (login: String, avatarURL: URL?)
    /// Validates an explicit token against the GitHub API, bypassing the
    /// ambient token provider. Used by IdentityActor.swap before committing.
    func validateToken(_ token: String) async throws -> (login: String, avatarURL: URL?)
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

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Invalid or missing GitHub token. Check your token in Settings."
        case .rateLimited:
            "GitHub API rate limit exceeded. Wait a few minutes and try again."
        case .permissionDenied(let detail):
            if let detail, !detail.isEmpty {
                "GitHub refused the request: \(detail)."
            } else {
                "GitHub refused the request. Check that your token has the required scopes."
            }
        case .clientError(let statusCode):
            "Request error (HTTP \(statusCode)). Check that your query uses valid GitHub search syntax."
        case .serverError(let statusCode):
            "GitHub is experiencing issues (HTTP \(statusCode)). Try again later."
        case .graphQLErrors(let messages):
            "GitHub API error: \(messages.joined(separator: "; "))"
        case .networkError(let error):
            "Network error: \(error.localizedDescription)"
        case .decodingError:
            "Unexpected response from GitHub. Check that your query uses valid GitHub search qualifiers (e.g. \"is:pr is:open review-requested:@me\")."
        }
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
            return .serverError(statusCode: code)
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
    private let logger = Logger(subsystem: "PullRequestPilot", category: "GitHubClient")

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

    func fetchPullRequests(query searchQuery: String, cursor: String? = nil) async throws -> PullRequestPage {
        let query = GitHubGraphQL.searchQuery(query: searchQuery, cursor: cursor)
        let response: GraphQLResponse<SearchData> = try await execute(query: query)

        if let errors = response.errors, !errors.isEmpty, response.data != nil {
            logger.warning("GraphQL partial errors: \(errors.map(\.message).joined(separator: "; "), privacy: .public)")
        }

        guard let data = response.data else {
            let messages = response.errors?.map(\.message) ?? ["Unknown error"]
            throw GitHubClientError.graphQLErrors(messages)
        }

        let prs = data.search.nodes.compactMap { $0.toDomain() }
        let skipped = data.search.skippedNodeCount
        if skipped > 0 {
            logger.warning("Skipped \(skipped, privacy: .public) node(s) that failed to decode as pull requests")
        }
        logger.info("Page returned \(data.search.nodes.count, privacy: .public) node(s), mapped \(prs.count, privacy: .public) PR(s)")

        let rawCursor = data.search.pageInfo.hasNextPage ? data.search.pageInfo.endCursor : nil
        let nextCursor = rawCursor?.isEmpty == false ? rawCursor : nil
        return PullRequestPage(pullRequests: prs, nextCursor: nextCursor, skippedNodeCount: skipped)
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
            return TimelinePage(events: [], checkRuns: [], reviewers: [], nextCursor: nil, checksNextCursor: nil)
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
        return TimelinePage(events: events, checkRuns: checkRuns, reviewers: reviewers, nextCursor: nextCursor, checksNextCursor: checksNextCursor)
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

        let checkRuns = data.node?.commits?.toDomain(pageOffset: checksPageOffset) ?? []
        let pageInfo = data.node?.commits?.nodes.first?.commit.statusCheckRollup?.contexts.pageInfo
        let rawCheckCursor = pageInfo?.hasNextPage == true ? pageInfo?.endCursor : nil
        let nextCursor = rawCheckCursor?.isEmpty == false ? rawCheckCursor : nil
        return ChecksPage(checkRuns: checkRuns, nextCursor: nextCursor)
    }

    func fetchViewer() async throws -> (login: String, avatarURL: URL?) {
        let response: GraphQLResponse<ViewerData> = try await execute(query: GitHubGraphQL.viewerQuery)
        return try viewerResult(from: response)
    }

    func validateToken(_ token: String) async throws -> (login: String, avatarURL: URL?) {
        let response: GraphQLResponse<ViewerData> = try await execute(query: GitHubGraphQL.viewerQuery, overrideToken: token)
        return try viewerResult(from: response)
    }

    // MARK: - Private

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

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["query": query]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

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
                break
            case 401:
                onUnauthorized(token)
                throw GitHubClientError.unauthorized
            case 403:
                // Only treat 403 as rate-limit when the rate-limit headers say so.
                // A bare 403 with no rate headers is a permission/scope error.
                if Self.isRateLimited(response: httpResponse) {
                    throw GitHubClientError.rateLimited(retryAfter: Self.parseRetryAfter(from: httpResponse))
                }
                throw GitHubClientError.permissionDenied(detail: Self.extractErrorMessage(from: data))
            case 429:
                throw GitHubClientError.rateLimited(retryAfter: Self.parseRetryAfter(from: httpResponse))
            case 400...499:
                throw GitHubClientError.clientError(statusCode: httpResponse.statusCode)
            case 500...599:
                throw GitHubClientError.serverError(statusCode: httpResponse.statusCode)
            default:
                break
            }
        }

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
