import Foundation

// MARK: - GraphQL Response Envelope

struct GraphQLResponse<T: Decodable>: Decodable {
    let data: T?
    let errors: [GraphQLError]?
}

struct GraphQLError: Decodable {
    let message: String
}

// MARK: - Search Response

struct SearchData: Decodable {
    let search: SearchResult
}

struct SearchResult: Decodable {
    let nodes: [PullRequestNode]
    let pageInfo: PageInfo
}

struct PageInfo: Decodable {
    let hasNextPage: Bool
    let endCursor: String?
}

struct PullRequestNode: Decodable {
    let id: String
    let number: Int
    let title: String
    let url: String
    let createdAt: String
    let updatedAt: String
    let additions: Int
    let deletions: Int
    let isDraft: Bool
    let reviewDecision: String?
    let baseRefName: String
    let headRefName: String
    let repository: RepositoryNode
    let author: AuthorNode?
    let labels: LabelsConnection

    struct RepositoryNode: Decodable {
        let nameWithOwner: String
    }

    struct AuthorNode: Decodable {
        let login: String
        let avatarUrl: String?
    }

    struct LabelsConnection: Decodable {
        let nodes: [LabelNode]
    }

    struct LabelNode: Decodable {
        let name: String
        let color: String
    }
}

// MARK: - Viewer Response

struct ViewerData: Decodable {
    let viewer: ViewerNode
}

struct ViewerNode: Decodable {
    let login: String
}

// MARK: - DTO → Domain Mapping

extension PullRequestNode {
    func toDomain() -> PullRequest? {
        guard let url = URL(string: url) else { return nil }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]

        guard let created = isoFormatter.date(from: createdAt) ?? fallbackFormatter.date(from: createdAt),
              let updated = isoFormatter.date(from: updatedAt) ?? fallbackFormatter.date(from: updatedAt) else {
            return nil
        }

        return PullRequest(
            id: id,
            number: number,
            title: title,
            url: url,
            repository: Repository(nameWithOwner: repository.nameWithOwner),
            author: Author(
                login: author?.login ?? "ghost",
                avatarURL: author?.avatarUrl.flatMap(URL.init(string:))
            ),
            createdAt: created,
            updatedAt: updated,
            additions: additions,
            deletions: deletions,
            isDraft: isDraft,
            reviewDecision: reviewDecision.flatMap(ReviewDecision.init(rawValue:)),
            labels: labels.nodes.map { Label(name: $0.name, color: $0.color) },
            baseRefName: baseRefName,
            headRefName: headRefName
        )
    }
}
