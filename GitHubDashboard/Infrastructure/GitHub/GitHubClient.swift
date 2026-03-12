import Foundation
import os

// MARK: - Protocol

protocol GitHubClientProtocol: Sendable {
    func fetchPullRequests(query: String) async throws -> [PullRequest]
    func fetchViewerLogin() async throws -> String
}

// MARK: - Errors

enum GitHubClientError: LocalizedError {
    case unauthorized
    case graphQLErrors([String])
    case networkError(Error)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Invalid or missing GitHub token. Check your token in Settings."
        case .graphQLErrors(let messages):
            "GitHub API error: \(messages.joined(separator: ", "))"
        case .networkError(let error):
            "Network error: \(error.localizedDescription)"
        case .decodingError(let error):
            "Failed to parse response: \(error.localizedDescription)"
        }
    }
}

// MARK: - Implementation

final class GitHubClient: GitHubClientProtocol, Sendable {
    private let tokenProvider: @Sendable () -> String?
    private let session: URLSession
    private let logger = Logger(subsystem: "GitHubDashboard", category: "GitHubClient")

    private static let endpoint = URL(string: "https://api.github.com/graphql")!

    init(tokenProvider: @escaping @Sendable () -> String?, session: URLSession = .shared) {
        self.tokenProvider = tokenProvider
        self.session = session
    }

    func fetchPullRequests(query searchQuery: String) async throws -> [PullRequest] {
        var allPullRequests: [PullRequest] = []
        var cursor: String? = nil

        repeat {
            let query = GitHubGraphQL.searchQuery(query: searchQuery, cursor: cursor)
            let response: GraphQLResponse<SearchData> = try await execute(query: query)

            guard let data = response.data else {
                let messages = response.errors?.map(\.message) ?? ["Unknown error"]
                throw GitHubClientError.graphQLErrors(messages)
            }

            let nodeCount = data.search.nodes.count
            let prs = data.search.nodes.compactMap { $0.toDomain() }
            let skipped = nodeCount - prs.count
            logger.info("Page returned \(nodeCount) node(s), mapped \(prs.count) PR(s), skipped \(skipped)")

            if skipped > 0 {
                logger.warning("Some nodes failed domain mapping — likely missing fields in API response")
            }

            allPullRequests.append(contentsOf: prs)

            cursor = data.search.pageInfo.hasNextPage ? data.search.pageInfo.endCursor : nil
        } while cursor != nil

        logger.info("Total: \(allPullRequests.count) review request(s)")
        return allPullRequests.sorted { $0.updatedAt > $1.updatedAt }
    }

    func fetchViewerLogin() async throws -> String {
        let response: GraphQLResponse<ViewerData> = try await execute(query: GitHubGraphQL.viewerQuery)

        guard let data = response.data else {
            let messages = response.errors?.map(\.message) ?? ["Unknown error"]
            throw GitHubClientError.graphQLErrors(messages)
        }

        return data.viewer.login
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

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
            throw GitHubClientError.unauthorized
        }

        do {
            return try JSONDecoder().decode(GraphQLResponse<T>.self, from: data)
        } catch {
            throw GitHubClientError.decodingError(error)
        }
    }
}
