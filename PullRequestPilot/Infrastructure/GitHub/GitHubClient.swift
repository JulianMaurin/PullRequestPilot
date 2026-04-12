import Foundation
import os

// MARK: - Protocol

struct PullRequestPage: Sendable {
    let pullRequests: [PullRequest]
    let nextCursor: String?
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
    func fetchTimeline(nodeID: String, cursor: String?) async throws -> TimelinePage
    func fetchChecks(nodeID: String, cursor: String) async throws -> ChecksPage
    func fetchViewer() async throws -> (login: String, avatarURL: URL?)
}

// MARK: - Errors

enum GitHubClientError: LocalizedError {
    case unauthorized
    case rateLimited
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
}

extension Error {
    var isNetworkError: Bool {
        if let clientError = self as? GitHubClientError,
           case .networkError = clientError {
            return true
        }
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
    private let tokenProvider: @Sendable () -> String?
    private let session: URLSession
    private let logger = Logger(subsystem: "PullRequestPilot", category: "GitHubClient")

    private static let endpoint: URL = {
        guard let url = URL(string: "https://api.github.com/graphql") else {
            preconditionFailure("Invalid hardcoded GitHub API endpoint URL")
        }
        return url
    }()

    init(tokenProvider: @escaping @Sendable () -> String?, session: URLSession = .shared) {
        self.tokenProvider = tokenProvider
        self.session = session
    }

    func fetchPullRequests(query searchQuery: String, cursor: String? = nil) async throws -> PullRequestPage {
        let query = GitHubGraphQL.searchQuery(query: searchQuery, cursor: cursor)
        let response: GraphQLResponse<SearchData> = try await execute(query: query)

        guard let data = response.data else {
            let messages = response.errors?.map(\.message) ?? ["Unknown error"]
            throw GitHubClientError.graphQLErrors(messages)
        }

        let prs = data.search.nodes.compactMap { $0.toDomain() }
        logger.info("Page returned \(data.search.nodes.count, privacy: .public) node(s), mapped \(prs.count, privacy: .public) PR(s)")

        let nextCursor = data.search.pageInfo.hasNextPage ? data.search.pageInfo.endCursor : nil
        return PullRequestPage(pullRequests: prs, nextCursor: nextCursor)
    }

    func fetchTimeline(nodeID: String, cursor: String? = nil) async throws -> TimelinePage {
        let query = GitHubGraphQL.timelineQuery(nodeID: nodeID, cursor: cursor)
        let response: GraphQLResponse<TimelineNodeData> = try await execute(query: query)

        guard let data = response.data else {
            let messages = response.errors?.map(\.message) ?? ["Unknown error"]
            throw GitHubClientError.graphQLErrors(messages)
        }

        guard let prNode = data.node else {
            return TimelinePage(events: [], checkRuns: [], reviewers: [], nextCursor: nil, checksNextCursor: nil)
        }

        let events = prNode.timelineItems?.toDomain() ?? []
        let checkRuns = prNode.commits?.toDomain() ?? []
        let reviewers = prNode.toReviewers()
        let nextCursor = prNode.timelineItems?.pageInfo.hasNextPage == true
            ? prNode.timelineItems?.pageInfo.endCursor : nil
        let checksPageInfo = prNode.commits?.nodes.first?.commit.statusCheckRollup?.contexts.pageInfo
        let checksNextCursor = checksPageInfo?.hasNextPage == true ? checksPageInfo?.endCursor : nil
        return TimelinePage(events: events, checkRuns: checkRuns, reviewers: reviewers, nextCursor: nextCursor, checksNextCursor: checksNextCursor)
    }

    func fetchChecks(nodeID: String, cursor: String) async throws -> ChecksPage {
        let query = GitHubGraphQL.checksQuery(nodeID: nodeID, cursor: cursor)
        let response: GraphQLResponse<TimelineNodeData> = try await execute(query: query)

        guard let data = response.data else {
            let messages = response.errors?.map(\.message) ?? ["Unknown error"]
            throw GitHubClientError.graphQLErrors(messages)
        }

        let checkRuns = data.node?.commits?.toDomain() ?? []
        let pageInfo = data.node?.commits?.nodes.first?.commit.statusCheckRollup?.contexts.pageInfo
        let nextCursor = pageInfo?.hasNextPage == true ? pageInfo?.endCursor : nil
        return ChecksPage(checkRuns: checkRuns, nextCursor: nextCursor)
    }

    func fetchViewer() async throws -> (login: String, avatarURL: URL?) {
        let response: GraphQLResponse<ViewerData> = try await execute(query: GitHubGraphQL.viewerQuery)

        guard let data = response.data else {
            let messages = response.errors?.map(\.message) ?? ["Unknown error"]
            throw GitHubClientError.graphQLErrors(messages)
        }

        let avatarURL = data.viewer.avatarUrl.flatMap { URL(string: $0) }
        return (login: data.viewer.login, avatarURL: avatarURL)
    }

    // MARK: - Private

    private func execute<T: Decodable>(query: String) async throws -> GraphQLResponse<T> {
        guard let token = tokenProvider(), !token.isEmpty else {
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
                throw GitHubClientError.unauthorized
            case 403:
                throw GitHubClientError.rateLimited
            case 400...499:
                throw GitHubClientError.serverError(statusCode: httpResponse.statusCode)
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
}
