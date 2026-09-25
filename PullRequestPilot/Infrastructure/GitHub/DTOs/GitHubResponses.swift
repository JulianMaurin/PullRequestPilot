import Foundation
import os

private let searchResultLogger = Logger(category: "SearchResult")

// MARK: - GraphQL Response Envelope

struct GraphQLResponse<T: Decodable>: Decodable {
    let data: T?
    let errors: [GraphQLError]?
}

struct GraphQLError: Decodable {
    let message: String
    /// GitHub's error class, e.g. `RATE_LIMITED`, `FORBIDDEN`, `NOT_FOUND`.
    let type: String?
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
    /// Issues or discussions the query matched. Only `... on PullRequest`
    /// fields are selected, so these arrive as `{"__typename": "Issue"}`.
    let nonPullRequestCount: Int
    /// Null nodes: matches GitHub withheld, e.g. behind SAML SSO the token
    /// isn't authorized for. The reasons arrive in the response's `errors`.
    let withheldResultCount: Int
    /// Pull request nodes that failed to decode.
    let undecodablePullRequestCount: Int

    /// Decodes each node individually so one unexpected node can't fail the
    /// page, counting every node that doesn't become a pull request by cause.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pageInfo = try container.decode(PageInfo.self, forKey: .pageInfo)

        var nodesContainer = try container.nestedUnkeyedContainer(forKey: .nodes)
        var decoded: [PullRequestNode] = []
        var nonPullRequests = 0
        var withheld = 0
        var undecodable = 0
        while !nodesContainer.isAtEnd {
            // A null element must be consumed via decodeNil: decoding a
            // concrete type against null throws without advancing
            // currentIndex, so the loop would never terminate.
            if try nodesContainer.decodeNil() {
                withheld += 1
                continue
            }
            do {
                decoded.append(try nodesContainer.decode(PullRequestNode.self))
            } catch {
                let indexBefore = nodesContainer.currentIndex
                // Advance past the undecodable node
                let skippedNode = try? nodesContainer.decode(SkippedNode.self)
                if skippedNode?.typename == "PullRequest" {
                    undecodable += 1
                    searchResultLogger.error("Dropped a pull request that failed to decode: \(error, privacy: .public)")
                } else {
                    nonPullRequests += 1
                }
                // Failed decode attempts do not advance currentIndex; if
                // neither attempt consumed the element, fail the decode
                // rather than loop forever.
                if nodesContainer.currentIndex == indexBefore {
                    throw DecodingError.dataCorrupted(DecodingError.Context(
                        codingPath: nodesContainer.codingPath,
                        debugDescription: "Search node at index \(indexBefore) is neither decodable nor skippable"
                    ))
                }
            }
        }
        nodes = decoded
        nonPullRequestCount = nonPullRequests
        withheldResultCount = withheld
        undecodablePullRequestCount = undecodable
    }

    private enum CodingKeys: String, CodingKey {
        case nodes, pageInfo
    }

    /// Advances past a node that isn't a decodable pull request and says
    /// whether it was one.
    private struct SkippedNode: Decodable {
        let typename: String?

        private enum CodingKeys: String, CodingKey {
            case typename = "__typename"
        }
    }
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
    let isCrossRepository: Bool?
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
        /// Selected on PR authors only; `Bot` marks a GitHub App account.
        let typename: String?

        init(login: String, avatarUrl: String?, typename: String? = nil) {
            self.login = login
            self.avatarUrl = avatarUrl
            self.typename = typename
        }

        private enum CodingKeys: String, CodingKey {
            case login, avatarUrl
            case typename = "__typename"
        }
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
        let typename: String
        let createdAt: String?
        let author: AuthorNode?
        let actor: AuthorNode?
        let state: String?
        let commit: CommitNode?

        private enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case createdAt, author, actor, state, commit
        }

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

// MARK: - Draft State Mutation Response

struct DraftStateMutationData: Decodable {
    let payload: DraftStateMutationPayload?
}

struct DraftStateMutationPayload: Decodable {
    let pullRequest: DraftStatePullRequest?
}

struct DraftStatePullRequest: Decodable {
    let isDraft: Bool
}

// MARK: - Timeline Response

struct TimelineNodeData: Decodable {
    let node: TimelinePullRequestNode?
}

struct TimelinePullRequestNode: Decodable {
    let timelineItems: TimelineItemsConnection?
    let reviewRequests: ReviewRequestsConnection?
    /// Latest approve / request-changes per user, including users whose
    /// review was re-requested.
    let latestOpinionatedReviews: ReviewsConnection?
    /// Latest review of any state per user, excluding users with a pending
    /// request. Supplies comment-only reviewers.
    let latestReviews: ReviewsConnection?
    let commits: CheckRunCommitsConnection?
    let author: PullRequestNode.AuthorNode?
}

// MARK: - Reviewer DTOs

struct ReviewRequestsConnection: Decodable {
    let nodes: [ReviewRequestNode]
}

struct ReviewRequestNode: Decodable {
    let requestedReviewer: RequestedReviewerNode?
}

struct RequestedReviewerNode: Decodable {
    let typename: String
    let login: String?
    let name: String?
    let avatarUrl: String?

    private enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case login, name, avatarUrl
    }
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
    /// GitHub's reviewer rollup: an approve or request-changes stands until a
    /// later one replaces it (thread replies are COMMENTED reviews and must not
    /// demote it), a pending request shows as awaiting even over an earlier
    /// review, and the PR author's own replies don't make them a reviewer.
    func toReviewers() -> [Reviewer] {
        let prAuthor = author?.login
        var states: [String: (state: ReviewerState, avatarUrl: String?)] = [:]
        var order: [String] = []

        func record(_ node: ReviewNode) {
            guard let reviewAuthor = node.author, reviewAuthor.login != prAuthor,
                  let state = Self.reviewerState(node.state),
                  states[reviewAuthor.login] == nil
            else { return }
            order.append(reviewAuthor.login)
            states[reviewAuthor.login] = (state, reviewAuthor.avatarUrl)
        }
        (latestOpinionatedReviews?.nodes ?? []).forEach(record)
        (latestReviews?.nodes ?? []).forEach(record)

        var requested: [(id: String, displayName: String, avatarUrl: String?, isTeam: Bool)] = []
        for node in reviewRequests?.nodes ?? [] {
            guard let reviewer = node.requestedReviewer else { continue }
            let isTeam = reviewer.typename == "Team" || reviewer.typename == "EnterpriseTeam"
            let displayName = (isTeam ? reviewer.name : reviewer.login) ?? reviewer.typename
            let id = isTeam ? "team-\(displayName)" : displayName
            requested.append((id, displayName, reviewer.avatarUrl, isTeam))
        }
        let requestedIDs = Set(requested.map(\.id))

        var reviewers = order.compactMap { login -> Reviewer? in
            guard let entry = states[login] else { return nil }
            let state: ReviewerState = requestedIDs.contains(login) ? .pending : entry.state
            return Reviewer(id: login, displayName: login, avatarURL: entry.avatarUrl.flatMap(URL.init), isTeam: false, state: state)
        }
        var seen = Set(order)
        for request in requested where seen.insert(request.id).inserted {
            reviewers.append(Reviewer(
                id: request.id,
                displayName: request.displayName,
                avatarURL: request.avatarUrl.flatMap(URL.init),
                isTeam: request.isTeam,
                state: .pending
            ))
        }
        return reviewers
    }

    private static func reviewerState(_ raw: String) -> ReviewerState? {
        switch raw {
        case "APPROVED": .approved
        case "CHANGES_REQUESTED": .changesRequested
        case "COMMENTED": .commented
        case "DISMISSED": .dismissed
        default: nil
        }
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
    let typename: String
    let name: String?
    let status: String?
    let conclusion: String?
    let detailsUrl: String?
    let isRequired: Bool?
    let startedAt: String?
    let checkSuite: CheckSuiteNode?
    let context: String?
    let state: String?
    let targetUrl: String?

    private enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case name, status, conclusion, detailsUrl, isRequired, startedAt, checkSuite
        case context, state, targetUrl
    }

    struct CheckSuiteNode: Decodable {
        let workflowRun: WorkflowRunNode?
    }

    struct WorkflowRunNode: Decodable {
        let databaseId: Int?
    }
}

extension CheckRunCommitsConnection {
    /// Maps a single page of the check-run rollup to domain `CheckRun`s and
    /// dedupes by `(name, workflowRunID)`. Within a group, the run with the
    /// latest `startedAt` wins. Runs with no `workflowRunID` (StatusContexts
    /// and CheckRuns without a check suite) dedupe by name alone.
    ///
    /// CheckRun nodes are processed before StatusContext nodes so that when a
    /// name exists as both (rare but possible), the richer CheckRun fields
    /// win — the StatusContext with no workflowRunID keys on `name + nil`
    /// which collides with a CheckRun that also has a nil `workflowRunID`,
    /// and the priority-based tie-break keeps whichever has better state.
    func toDomain(pageOffset: Int = 0) -> [CheckRun] {
        guard let rollup = nodes.first?.commit.statusCheckRollup else { return [] }
        let allNodes = rollup.contexts.nodes

        let checkRunNodes = allNodes.filter { $0.typename == "CheckRun" }
        let statusContextNodes = allNodes.filter { $0.typename == "StatusContext" }

        var best: [CheckRunDedupeKey: CheckRun] = [:]
        var order: [CheckRunDedupeKey] = []
        // Keys claimed by CheckRun entries; used to skip a StatusContext
        // that would collide on `(name, nil)` with a CheckRun that also
        // happens to have a nil workflowRunID (Dependabot etc.). Tracked
        // separately because CheckRun entries with non-nil workflowRunID
        // key on a *different* `CheckRunDedupeKey` — we don't want to skip
        // the StatusContext in that case.
        var checkRunClaimedKeys: Set<CheckRunDedupeKey> = []
        var nextIndex = pageOffset

        func upsert(_ run: CheckRun) {
            let key = CheckRunDedupeKey(name: run.name, workflowRunID: run.workflowRunID)
            if let existing = best[key] {
                if Self.isLater(run, than: existing) {
                    best[key] = run
                }
            } else {
                order.append(key)
                best[key] = run
            }
        }

        for node in checkRunNodes {
            guard let name = node.name else { continue }
            let globalIndex = nextIndex
            nextIndex += 1
            let status = node.status.flatMap { CheckRunStatus(rawValue: $0) } ?? .queued
            let conclusion = node.conclusion.flatMap { CheckRunConclusion(rawValue: $0) }
            let url = node.detailsUrl.flatMap { URL(string: $0) }
            let workflowRunID = node.checkSuite?.workflowRun?.databaseId
            let startedAt = node.startedAt.flatMap(parseISO8601Date)
            // Include workflowRunID in the synthesized ID so SwiftUI `ForEach`
            // keeps distinct `(name, workflowRunID)` entries distinct even
            // when they share an index bucket.
            let idSuffix = workflowRunID.map { "-\($0)" } ?? ""
            let run = CheckRun(
                id: "check-\(globalIndex)-\(name)\(idSuffix)",
                name: name,
                status: status,
                conclusion: conclusion,
                detailsURL: url,
                isRequired: node.isRequired ?? false,
                workflowRunID: workflowRunID,
                startedAt: startedAt
            )
            checkRunClaimedKeys.insert(CheckRunDedupeKey(name: run.name, workflowRunID: run.workflowRunID))
            upsert(run)
        }

        for node in statusContextNodes {
            guard let context = node.context else { continue }
            let key = CheckRunDedupeKey(name: context, workflowRunID: nil)
            // If a CheckRun with nil workflowRunID already claimed this key,
            // prefer the richer CheckRun data and drop the StatusContext.
            if checkRunClaimedKeys.contains(key) { continue }
            let globalIndex = nextIndex
            nextIndex += 1
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
            let run = CheckRun(
                id: "status-\(globalIndex)-\(context)",
                name: context,
                status: status,
                conclusion: conclusion,
                detailsURL: url,
                isRequired: false,
                workflowRunID: nil,
                startedAt: nil
            )
            upsert(run)
        }

        return order.compactMap { best[$0] }
    }

    private static func isLater(_ candidate: CheckRun, than current: CheckRun) -> Bool {
        switch (candidate.startedAt, current.startedAt) {
        case let (.some(a), .some(b)) where a != b:
            return a > b
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return candidate.conclusionPriority > current.conclusionPriority
        }
    }
}

struct TimelineItemsConnection: Decodable {
    let nodes: [TimelineItemDetailNode]
    let pageInfo: PageInfo
}

struct TimelineItemDetailNode: Decodable {
    let typename: String
    let createdAt: String?
    let author: PullRequestNode.AuthorNode?
    let actor: PullRequestNode.AuthorNode?
    let state: String?
    let body: String?
    let commit: CommitDetailNode?
    let assignee: AssigneeNode?
    let requestedReviewer: RequestedReviewerNode?

    private enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case createdAt, author, actor, state, body, commit, assignee, requestedReviewer
    }

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
    func toDomain(pageOffset: Int = 0) -> [TimelineEvent] {
        return nodes.enumerated().compactMap { index, node in
            let globalIndex = pageOffset + index
            let kind: TimelineEventKind
            let actorNode: PullRequestNode.AuthorNode?
            let dateString: String?
            let body: String?

            switch node.typename {
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
                id: "\(globalIndex)-\(node.typename)-\(dateStr)-\(actorNode?.login ?? "")",
                kind: kind,
                actor: actor,
                timestamp: date,
                body: body
            )
        }
    }
}

// MARK: - ISO 8601 Dates

/// A Sendable value type: shared across threads without a lock. Its lenient
/// parse reads timestamps with or without fractional seconds.
private let iso8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

/// Callers log the timestamps that don't parse.
private func parseISO8601Date(_ string: String) -> Date? {
    try? iso8601.parse(string)
}

// MARK: - DTO → Domain Mapping

extension PullRequestNode {
    func toDomain() -> PullRequest? {
        guard let url = URL(string: url) else {
            searchResultLogger.error("Dropping PR #\(number, privacy: .public) — URL failed to parse: \(url, privacy: .private)")
            return nil
        }

        guard let created = parseISO8601Date(createdAt),
              let updated = parseISO8601Date(updatedAt) else {
            searchResultLogger.error("Failed to parse ISO8601 date for PR #\(number, privacy: .public): createdAt=\(createdAt, privacy: .public), updatedAt=\(updatedAt, privacy: .public)")
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
                avatarURL: author?.avatarUrl.flatMap(URL.init(string:)),
                isBot: author?.typename == "Bot"
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
            isCrossRepository: isCrossRepository ?? false,
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

        switch node.typename {
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
