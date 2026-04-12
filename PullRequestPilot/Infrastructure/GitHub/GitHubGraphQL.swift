import Foundation

enum GitHubGraphQL {
    static func searchQuery(query: String, cursor: String? = nil) -> String {
        let escapedQuery = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let after = cursor.map { ", after: \"\($0)\"" } ?? ""
        return """
        {
          search(query: "\(escapedQuery)", type: ISSUE, first: 50\(after)) {
            nodes {
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
                repository {
                  nameWithOwner
                }
                author {
                  login
                  avatarUrl
                }
                reviewThreads(first: 100) {
                  totalCount
                  nodes {
                    isResolved
                  }
                }
                latestReviews(first: 100) {
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
    }

    static func timelineQuery(nodeID: String, cursor: String? = nil) -> String {
        let after = cursor.map { ", after: \"\($0)\"" } ?? ""
        return """
        {
          node(id: "\(nodeID)") {
            ... on PullRequest {
              timelineItems(first: 100, itemTypes: [
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
              ]\(after)) {
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
                    }
                  }
                  ... on ReviewRequestedEvent {
                    createdAt
                    actor { login avatarUrl }
                    requestedReviewer {
                      ... on User { login }
                      ... on Team { name }
                    }
                  }
                }
                pageInfo {
                  hasNextPage
                  endCursor
                }
              }
              commits(last: 1) {
                nodes {
                  commit {
                    statusCheckRollup {
                      contexts(first: 100) {
                        nodes {
                          __typename
                          ... on CheckRun {
                            name
                            status
                            conclusion
                            detailsUrl
                            isRequired(pullRequestId: "\(nodeID)")
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
                    }
                  }
                }
              }
            }
          }
        }
        """
    }

    static func checksQuery(nodeID: String, cursor: String) -> String {
        """
        {
          node(id: "\(nodeID)") {
            ... on PullRequest {
              commits(last: 1) {
                nodes {
                  commit {
                    statusCheckRollup {
                      contexts(first: 100, after: "\(cursor)") {
                        nodes {
                          __typename
                          ... on CheckRun {
                            name
                            status
                            conclusion
                            detailsUrl
                            isRequired(pullRequestId: "\(nodeID)")
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
                    }
                  }
                }
              }
            }
          }
        }
        """
    }

    static let viewerQuery = """
    {
      viewer {
        login
        avatarUrl
      }
    }
    """
}
