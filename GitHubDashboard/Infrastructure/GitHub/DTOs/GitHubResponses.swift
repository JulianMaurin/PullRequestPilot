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
    let state: String
    let isDraft: Bool
    let reviewDecision: String?
    let commits: CommitsConnection?
    let baseRefName: String
    let headRefName: String
    let headRefOid: String?
    let repository: RepositoryNode
    let author: AuthorNode?
    let reviewThreads: ReviewThreadsConnection?
    let labels: LabelsConnection

    struct RepositoryNode: Decodable {
        let nameWithOwner: String
    }

    struct AuthorNode: Decodable {
        let login: String
        let avatarUrl: String?
    }

    struct CommitsConnection: Decodable {
        let nodes: [CommitWrapper]

        struct CommitWrapper: Decodable {
            let commit: CommitDetail

            struct CommitDetail: Decodable {
                let statusCheckRollup: StatusCheckRollup?

                struct StatusCheckRollup: Decodable {
                    let state: String
                }
            }
        }
    }

    struct ReviewThreadsConnection: Decodable {
        let totalCount: Int
        let nodes: [ReviewThreadNode]

        struct ReviewThreadNode: Decodable {
            let isResolved: Bool
        }
    }

    struct LabelsConnection: Decodable {
        let nodes: [LabelNode]
    }

    struct LabelNode: Decodable {
        let name: String
        let color: String
    }

    struct TimelineConnection: Decodable {
        let nodes: [TimelineItemNode]
    }

    struct TimelineItemNode: Decodable {
        // swiftlint:disable:next identifier_name
        let __typename: String
        let createdAt: String?
        let author: AuthorNode?
        let actor: AuthorNode?
        let state: String?
        let commit: CommitNode?

        struct CommitNode: Decodable {
            let author: CommitAuthorNode?
            let committedDate: String?

            struct CommitAuthorNode: Decodable {
                let user: AuthorNode?
            }
        }
    }

    let timelineItems: TimelineConnection?
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
            state: PullRequestState(rawValue: state) ?? .open,
            isDraft: isDraft,
            checkStatus: commits?.nodes.first?.commit.statusCheckRollup.flatMap { CheckStatus(rawValue: $0.state) },
            reviewDecision: reviewDecision.flatMap(ReviewDecision.init(rawValue:)),
            totalThreads: reviewThreads?.totalCount ?? 0,
            unresolvedThreads: reviewThreads?.nodes.filter { !$0.isResolved }.count ?? 0,
            labels: labels.nodes.map { Label(name: $0.name, color: $0.color) },
            baseRefName: baseRefName,
            headRefName: headRefName,
            headCommitSha: headRefOid,
            lastActivity: mapLastActivity(isoFormatter: isoFormatter, fallbackFormatter: fallbackFormatter)
        )
    }

    private func mapLastActivity(isoFormatter: ISO8601DateFormatter, fallbackFormatter: ISO8601DateFormatter) -> LastActivity? {
        guard let node = timelineItems?.nodes.first else { return nil }

        let kind: ActivityKind
        let actorNode: AuthorNode?
        let dateString: String?

        switch node.__typename {
        case "IssueComment":
            kind = .comment
            actorNode = node.author
            dateString = node.createdAt
        case "PullRequestReview":
            let state: ReviewDecision? = node.state.flatMap {
                switch $0 {
                case "APPROVED": .approved
                case "CHANGES_REQUESTED": .changesRequested
                default: nil
                }
            }
            kind = .review(state)
            actorNode = node.author
            dateString = node.createdAt
        case "MergedEvent":
            kind = .merged
            actorNode = node.actor
            dateString = node.createdAt
        case "ClosedEvent":
            kind = .closed
            actorNode = node.actor
            dateString = node.createdAt
        case "HeadRefForcePushedEvent":
            kind = .forcePushed
            actorNode = node.actor
            dateString = node.createdAt
        case "PullRequestCommit":
            kind = .committed
            actorNode = node.commit?.author?.user
            dateString = node.commit?.committedDate ?? node.createdAt
        default:
            return nil
        }

        guard let dateStr = dateString,
              let date = isoFormatter.date(from: dateStr) ?? fallbackFormatter.date(from: dateStr) else {
            return nil
        }

        let actor = actorNode.map { Author(login: $0.login, avatarURL: $0.avatarUrl.flatMap(URL.init(string:))) }
        return LastActivity(kind: kind, actor: actor, timestamp: date)
    }
}
