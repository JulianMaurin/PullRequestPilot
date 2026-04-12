import Foundation
import os

// MARK: - GraphQL Response Envelope

struct GraphQLResponse<T: Decodable>: Decodable {
    let data: T?
    let errors: [GraphQLError]?
}

struct GraphQLError: Decodable {
    let message: String
}

/// Lightweight type for extracting errors when the full response fails to decode.
struct GraphQLErrorResponse: Decodable {
    let errors: [GraphQLError]?
}

// MARK: - Search Response

struct SearchData: Decodable {
    let search: SearchResult
}

struct SearchResult: Decodable {
    let nodes: [PullRequestNode]
    let pageInfo: PageInfo

    /// Custom decoding: the `type: ISSUE` search can return non-PR nodes that
    /// lack `... on PullRequest` fields. Decode each node individually and
    /// silently skip any that fail (e.g. plain Issue nodes).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pageInfo = try container.decode(PageInfo.self, forKey: .pageInfo)

        var nodesContainer = try container.nestedUnkeyedContainer(forKey: .nodes)
        var decoded: [PullRequestNode] = []
        while !nodesContainer.isAtEnd {
            if let node = try? nodesContainer.decode(PullRequestNode.self) {
                decoded.append(node)
            } else {
                // Skip non-PullRequest nodes (plain Issues) that fail to decode
                _ = try? nodesContainer.decode(EmptyNode.self)
            }
        }
        nodes = decoded
    }

    private enum CodingKeys: String, CodingKey {
        case nodes, pageInfo
    }

    /// Minimal type that always succeeds decoding, used to advance the container past a skipped node.
    private struct EmptyNode: Decodable {}
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
    let latestReviews: LatestReviewsConnection?
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

    struct LatestReviewsConnection: Decodable {
        let nodes: [LatestReviewNode]

        struct LatestReviewNode: Decodable {
            let author: AuthorNode?
            let state: String
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
    let avatarUrl: String?
}

// MARK: - Timeline Response

struct TimelineNodeData: Decodable {
    let node: TimelinePullRequestNode?
}

struct TimelinePullRequestNode: Decodable {
    let timelineItems: TimelineItemsConnection?
    let reviewRequests: ReviewRequestsConnection?
    let reviews: ReviewsConnection?
    let commits: CheckRunCommitsConnection?
}

// MARK: - Reviewer DTOs

struct ReviewRequestsConnection: Decodable {
    let nodes: [ReviewRequestNode]
}

struct ReviewRequestNode: Decodable {
    let requestedReviewer: RequestedReviewerNode?
}

struct RequestedReviewerNode: Decodable {
    // swiftlint:disable:next identifier_name
    let __typename: String
    let login: String?
    let name: String?
    let avatarUrl: String?
}

struct ReviewsConnection: Decodable {
    let nodes: [ReviewNode]
}

struct ReviewNode: Decodable {
    struct ReviewAuthorNode: Decodable {
        let login: String
        let avatarUrl: String?
    }
    let author: ReviewAuthorNode?
    let state: String
}

extension TimelinePullRequestNode {
    func toReviewers() -> [Reviewer] {
        var reviewers: [Reviewer] = []
        var seen = Set<String>()

        // Keep the latest review per author (last occurrence in the list wins).
        var latestState: [String: (state: ReviewerState, avatarUrl: String?)] = [:]
        var authorOrder: [String] = []

        for node in (reviews?.nodes ?? []) {
            guard let author = node.author else { continue }
            let state: ReviewerState = switch node.state {
            case "APPROVED": .approved
            case "CHANGES_REQUESTED": .changesRequested
            case "COMMENTED": .commented
            case "DISMISSED": .dismissed
            default: .commented
            }
            if latestState[author.login] == nil {
                authorOrder.append(author.login)
            }
            latestState[author.login] = (state, author.avatarUrl)
        }

        for login in authorOrder {
            guard let entry = latestState[login], seen.insert(login).inserted else { continue }
            let avatarURL = entry.avatarUrl.flatMap(URL.init)
            reviewers.append(Reviewer(id: login, displayName: login, avatarURL: avatarURL, isTeam: false, state: entry.state))
        }

        // Then, add requested reviewers who haven't reviewed yet
        for node in (reviewRequests?.nodes ?? []) {
            guard let requested = node.requestedReviewer else { continue }
            let isTeam = requested.__typename == "Team"
            let displayName = isTeam ? (requested.name ?? "team") : (requested.login ?? "user")
            let id = isTeam ? "team-\(displayName)" : displayName
            guard seen.insert(id).inserted else { continue }
            let avatarURL = requested.avatarUrl.flatMap { URL(string: $0) }
            reviewers.append(Reviewer(id: id, displayName: displayName, avatarURL: avatarURL, isTeam: isTeam, state: .pending))
        }

        return reviewers
    }
}

// MARK: - Check Run DTOs

struct CheckRunCommitsConnection: Decodable {
    let nodes: [CheckRunCommitWrapper]

    struct CheckRunCommitWrapper: Decodable {
        let commit: CheckRunCommitDetail
    }

    struct CheckRunCommitDetail: Decodable {
        let statusCheckRollup: CheckRunRollup?
    }

    struct CheckRunRollup: Decodable {
        let contexts: CheckRunContextsConnection
    }

    struct CheckRunContextsConnection: Decodable {
        let nodes: [CheckRunContextNode]
        let pageInfo: PageInfo?
    }
}

struct CheckRunContextNode: Decodable {
    // swiftlint:disable:next identifier_name
    let __typename: String
    // CheckRun fields
    let name: String?
    let status: String?
    let conclusion: String?
    let detailsUrl: String?
    let isRequired: Bool?
    // StatusContext fields
    let context: String?
    let state: String?
    let targetUrl: String?
}

extension CheckRunCommitsConnection {
    func toDomain() -> [CheckRun] {
        guard let rollup = nodes.first?.commit.statusCheckRollup else { return [] }
        let allNodes = rollup.contexts.nodes

        // Process CheckRun first (richer data), then StatusContext for any not already seen
        let checkRunNodes = allNodes.enumerated().filter { $0.element.__typename == "CheckRun" }
        let statusContextNodes = allNodes.enumerated().filter { $0.element.__typename == "StatusContext" }

        // Collect all entries per name, keeping the best one (success > in-progress > other > cancelled/stale)
        var bestByName: [String: CheckRun] = [:]
        var nameOrder: [String] = []

        for (index, node) in checkRunNodes {
            guard let name = node.name else { continue }
            let status = node.status.flatMap { CheckRunStatus(rawValue: $0) } ?? .queued
            let conclusion = node.conclusion.flatMap { CheckRunConclusion(rawValue: $0) }
            let url = node.detailsUrl.flatMap { URL(string: $0) }
            let run = CheckRun(id: "check-\(index)-\(name)", name: name, status: status, conclusion: conclusion, detailsURL: url, isRequired: node.isRequired ?? false)

            if let existing = bestByName[name] {
                // Keep the run with higher priority (success > in-progress > failure > cancelled)
                if run.conclusionPriority >= existing.conclusionPriority {
                    bestByName[name] = run
                }
            } else {
                nameOrder.append(name)
                bestByName[name] = run
            }
        }

        for (index, node) in statusContextNodes {
            guard let context = node.context, bestByName[context] == nil else { continue }
            let conclusion: CheckRunConclusion? = node.state.flatMap {
                switch $0 {
                case "SUCCESS": return .success
                case "FAILURE": return .failure
                case "ERROR": return .failure
                case "PENDING": return nil
                default: return nil
                }
            }
            let status: CheckRunStatus = node.state == "PENDING" ? .pending : .completed
            let url = node.targetUrl.flatMap { URL(string: $0) }
            nameOrder.append(context)
            bestByName[context] = CheckRun(id: "status-\(index)-\(context)", name: context, status: status, conclusion: conclusion, detailsURL: url, isRequired: false)
        }

        return nameOrder.compactMap { bestByName[$0] }
    }
}

struct TimelineItemsConnection: Decodable {
    let nodes: [TimelineItemDetailNode]
    let pageInfo: PageInfo
}

struct TimelineItemDetailNode: Decodable {
    // swiftlint:disable:next identifier_name
    let __typename: String
    let createdAt: String?
    let author: PullRequestNode.AuthorNode?
    let actor: PullRequestNode.AuthorNode?
    let state: String?
    let body: String?
    let commit: CommitDetailNode?
    let assignee: AssigneeNode?
    let requestedReviewer: RequestedReviewerNode?

    struct CommitDetailNode: Decodable {
        let committedDate: String?
        let message: String?
        let author: CommitAuthorWrapper?

        struct CommitAuthorWrapper: Decodable {
            let user: PullRequestNode.AuthorNode?
        }
    }

    struct AssigneeNode: Decodable {
        let login: String?
    }

    struct RequestedReviewerNode: Decodable {
        let login: String?
        let name: String?
    }
}

extension TimelineItemsConnection {
    func toDomain() -> [TimelineEvent] {
        return nodes.enumerated().compactMap { index, node in
            let kind: TimelineEventKind
            let actorNode: PullRequestNode.AuthorNode?
            let dateString: String?
            let body: String?

            switch node.__typename {
            case "IssueComment":
                kind = .comment
                actorNode = node.author
                dateString = node.createdAt
                body = node.body
            case "PullRequestReview":
                let reviewState: ReviewState? = node.state.flatMap { ReviewState(rawValue: $0) }
                kind = .review(reviewState)
                actorNode = node.author
                dateString = node.createdAt
                body = node.body
            case "MergedEvent":
                kind = .merged
                actorNode = node.actor
                dateString = node.createdAt
                body = nil
            case "ClosedEvent":
                kind = .closed
                actorNode = node.actor
                dateString = node.createdAt
                body = nil
            case "ReopenedEvent":
                kind = .reopened
                actorNode = node.actor
                dateString = node.createdAt
                body = nil
            case "HeadRefForcePushedEvent":
                kind = .forcePushed
                actorNode = node.actor
                dateString = node.createdAt
                body = nil
            case "PullRequestCommit":
                kind = .commit(message: node.commit?.message)
                actorNode = node.commit?.author?.user
                dateString = node.commit?.committedDate ?? node.createdAt
                body = nil
            case "ReadyForReviewEvent":
                kind = .readyForReview
                actorNode = node.actor
                dateString = node.createdAt
                body = nil
            case "ConvertToDraftEvent":
                kind = .convertedToDraft
                actorNode = node.actor
                dateString = node.createdAt
                body = nil
            case "AssignedEvent":
                kind = .assigned(assignee: node.assignee?.login ?? "unknown")
                actorNode = node.actor
                dateString = node.createdAt
                body = nil
            case "ReviewRequestedEvent":
                let reviewer = node.requestedReviewer?.login ?? node.requestedReviewer?.name ?? "unknown"
                kind = .reviewRequested(reviewer: reviewer)
                actorNode = node.actor
                dateString = node.createdAt
                body = nil
            default:
                return nil
            }

            guard let dateStr = dateString,
                  let date = parseISO8601Date(dateStr) else {
                return nil
            }

            let actor = actorNode.map { Author(login: $0.login, avatarURL: $0.avatarUrl.flatMap(URL.init(string:))) }
            return TimelineEvent(
                id: "\(index)-\(node.__typename)-\(dateStr)-\(actorNode?.login ?? "")",
                kind: kind,
                actor: actor,
                timestamp: date,
                body: body
            )
        }
    }
}

// MARK: - Shared ISO8601 Formatters

private enum ISO8601DateParsing {
    private static let lock = NSLock()

    private nonisolated(unsafe) static let primary: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let fallback: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return primary.date(from: string) ?? fallback.date(from: string)
    }
}

private func parseISO8601Date(_ string: String) -> Date? {
    ISO8601DateParsing.parse(string)
}

// MARK: - DTO → Domain Mapping

extension PullRequestNode {
    func toDomain() -> PullRequest? {
        guard let url = URL(string: url) else { return nil }

        guard let created = parseISO8601Date(createdAt),
              let updated = parseISO8601Date(updatedAt) else {
            os_log(.error, "Failed to parse ISO8601 date for PR #%d: createdAt=%{public}@, updatedAt=%{public}@", number, createdAt, updatedAt)
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
            lastActivity: mapLastActivity(),
            latestReviews: latestReviews?.nodes.compactMap { node in
                guard let login = node.author?.login,
                      let state = ReviewState(rawValue: node.state) else { return nil }
                return UserReview(login: login, state: state)
            } ?? []
        )
    }

    private func mapLastActivity() -> LastActivity? {
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
              let date = parseISO8601Date(dateStr) else {
            return nil
        }

        let actor = actorNode.map { Author(login: $0.login, avatarURL: $0.avatarUrl.flatMap(URL.init(string:))) }
        return LastActivity(kind: kind, actor: actor, timestamp: date)
    }
}
