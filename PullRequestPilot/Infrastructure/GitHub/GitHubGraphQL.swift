import Foundation

/// A GraphQL document and its variables: the request body GitHub receives.
/// Values travel as JSON variables, never spliced into the document, so no
/// user input needs escaping.
struct GraphQLRequest: Encodable, Hashable, Sendable {
    let query: String
    let variables: [String: GraphQLVariable]

    init(query: String, variables: [String: GraphQLVariable] = [:]) {
        self.query = query
        self.variables = variables
    }
}

enum GraphQLVariable: Encodable, Hashable, Sendable {
    case string(String)
    case int(Int)
    case null

    init(_ value: String?) {
        self = value.map(GraphQLVariable.string) ?? .null
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

enum GitHubGraphQL {
    static func searchQuery(query: String, cursor: String? = nil, pageSize: Int = Constants.App.searchPageSize) -> GraphQLRequest {
        GraphQLRequest(query: searchDocument, variables: [
            "query": .string(query),
            "pageSize": .int(pageSize),
            "cursor": GraphQLVariable(cursor),
        ])
    }

    static func timelineQuery(nodeID: String, cursor: String? = nil) -> GraphQLRequest {
        GraphQLRequest(query: timelineDocument, variables: [
            "id": .string(nodeID),
            "cursor": GraphQLVariable(cursor),
        ])
    }

    static func checksQuery(nodeID: String, cursor: String) -> GraphQLRequest {
        GraphQLRequest(query: checksDocument, variables: [
            "id": .string(nodeID),
            "cursor": .string(cursor),
        ])
    }

    static let viewerQuery = GraphQLRequest(query: """
    query Viewer {
      viewer {
        login
        avatarUrl
      }
    }
    """)

    /// Both mutations are aliased to `payload` so one response type decodes either.
    static func setDraftMutation(pullRequestID: String, isDraft: Bool) -> GraphQLRequest {
        let mutationName = isDraft ? "convertPullRequestToDraft" : "markPullRequestReadyForReview"
        return GraphQLRequest(query: """
        mutation SetDraftState($id: ID!) {
          payload: \(mutationName)(input: {pullRequestId: $id}) {
            pullRequest {
              isDraft
            }
          }
        }
        """, variables: ["id": .string(pullRequestID)])
    }

    // MARK: - Documents

    private static let searchDocument = """
    query SearchPullRequests($query: String!, $pageSize: Int!, $cursor: String) {
      search(query: $query, type: ISSUE, first: $pageSize, after: $cursor) {
        nodes {
          __typename
          ... on PullRequest {
            id
            number
            title
            url
            createdAt
            updatedAt
            additions
            deletions
            state
            isDraft
            reviewDecision
            commits(last: 1) {
              nodes {
                commit {
                  statusCheckRollup {
                    state
                  }
                }
              }
            }
            baseRefName
            headRefName
            headRefOid
            isCrossRepository
            repository {
              nameWithOwner
            }
            author {
              __typename
              login
              avatarUrl
            }
            reviewThreads(last: 100) {
              totalCount
              nodes {
                isResolved
              }
            }
            latestReviews(first: 20) {
              nodes {
                author { login }
                state
              }
            }
            labels(first: 10) {
              nodes {
                name
                color
              }
            }
            timelineItems(last: 1, itemTypes: [ISSUE_COMMENT, PULL_REQUEST_REVIEW, MERGED_EVENT, CLOSED_EVENT, HEAD_REF_FORCE_PUSHED_EVENT, PULL_REQUEST_COMMIT]) {
              nodes {
                __typename
                ... on IssueComment {
                  createdAt
                  author { login avatarUrl }
                }
                ... on PullRequestReview {
                  createdAt
                  state
                  author { login avatarUrl }
                }
                ... on MergedEvent {
                  createdAt
                  actor { login avatarUrl }
                }
                ... on ClosedEvent {
                  createdAt
                  actor { login avatarUrl }
                }
                ... on HeadRefForcePushedEvent {
                  createdAt
                  actor { login avatarUrl }
                }
                ... on PullRequestCommit {
                  commit {
                    committedDate
                    author {
                      user { login avatarUrl }
                    }
                  }
                }
              }
            }
          }
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
    """

    private static let timelineDocument = """
    query PullRequestTimeline($id: ID!, $cursor: String) {
      node(id: $id) {
        ... on PullRequest {
          timelineItems(first: 100, after: $cursor, itemTypes: [
            ISSUE_COMMENT,
            PULL_REQUEST_REVIEW,
            MERGED_EVENT,
            CLOSED_EVENT,
            HEAD_REF_FORCE_PUSHED_EVENT,
            PULL_REQUEST_COMMIT,
            REOPENED_EVENT,
            READY_FOR_REVIEW_EVENT,
            CONVERT_TO_DRAFT_EVENT,
            ASSIGNED_EVENT,
            REVIEW_REQUESTED_EVENT
          ]) {
            nodes {
              __typename
              ... on IssueComment {
                createdAt
                author { login avatarUrl }
                body
              }
              ... on PullRequestReview {
                createdAt
                state
                author { login avatarUrl }
                body
              }
              ... on MergedEvent {
                createdAt
                actor { login avatarUrl }
              }
              ... on ClosedEvent {
                createdAt
                actor { login avatarUrl }
              }
              ... on HeadRefForcePushedEvent {
                createdAt
                actor { login avatarUrl }
              }
              ... on PullRequestCommit {
                commit {
                  committedDate
                  message
                  author {
                    user { login avatarUrl }
                  }
                }
              }
              ... on ReopenedEvent {
                createdAt
                actor { login avatarUrl }
              }
              ... on ReadyForReviewEvent {
                createdAt
                actor { login avatarUrl }
              }
              ... on ConvertToDraftEvent {
                createdAt
                actor { login avatarUrl }
              }
              ... on AssignedEvent {
                createdAt
                actor { login avatarUrl }
                assignee {
                  ... on User { login }
                  ... on Bot { login }
                  ... on Mannequin { login }
                }
              }
              ... on ReviewRequestedEvent {
                createdAt
                actor { login avatarUrl }
                requestedReviewer {
                  ... on User { login }
                  ... on Team { name }
                  ... on Bot { login }
                  ... on Mannequin { login }
                }
              }
            }
            pageInfo {
              hasNextPage
              endCursor
            }
          }
          author { login }
          reviewRequests(first: 20) {
            nodes {
              requestedReviewer {
                __typename
                ... on User { login avatarUrl }
                ... on Team { name avatarUrl }
                ... on Bot { login avatarUrl }
                ... on Mannequin { login avatarUrl }
              }
            }
          }
          latestOpinionatedReviews(first: 100) {
            nodes {
              author { login avatarUrl }
              state
            }
          }
          latestReviews(first: 100) {
            nodes {
              author { login avatarUrl }
              state
            }
          }
          commits(last: 1) {
            nodes {
              commit {
                statusCheckRollup {
                  contexts(first: 100) {
                    ...CheckContexts
                  }
                }
              }
            }
          }
        }
      }
    }

    \(checkContextsFragment)
    """

    private static let checksDocument = """
    query PullRequestChecks($id: ID!, $cursor: String!) {
      node(id: $id) {
        ... on PullRequest {
          commits(last: 1) {
            nodes {
              commit {
                statusCheckRollup {
                  contexts(first: 100, after: $cursor) {
                    ...CheckContexts
                  }
                }
              }
            }
          }
        }
      }
    }

    \(checkContextsFragment)
    """

    /// Shared by the timeline's first page of checks and every later page.
    /// Reads the operation's `$id` for `isRequired`.
    private static let checkContextsFragment = """
    fragment CheckContexts on StatusCheckRollupContextConnection {
      nodes {
        __typename
        ... on CheckRun {
          name
          status
          conclusion
          detailsUrl
          startedAt
          isRequired(pullRequestId: $id)
          checkSuite {
            workflowRun {
              databaseId
            }
          }
        }
        ... on StatusContext {
          context
          state
          targetUrl
        }
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
    """
}
