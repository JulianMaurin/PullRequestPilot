import Foundation

enum GitHubGraphQL {
    private static func escapeGraphQL(_ value: String) -> String {
        var result = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        // Escape remaining ASCII control characters (U+0000–U+001F) as Unicode escapes
        result = String(result.flatMap { ch -> [Character] in
            guard let scalar = ch.unicodeScalars.first,
                  ch.unicodeScalars.count == 1,
                  scalar.value < 0x20,
                  scalar.value != 0x0A, // \n already handled
                  scalar.value != 0x0D, // \r already handled
                  scalar.value != 0x09  // \t already handled
            else { return [ch] }
            return Array(String(format: "\\u%04X", scalar.value))
        })
        return result
    }

    static func searchQuery(query: String, cursor: String? = nil) -> String {
        let escapedQuery = escapeGraphQL(query)
        let after = cursor.map { ", after: \"\(escapeGraphQL($0))\"" } ?? ""
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
                reviewThreads(first: 50) {
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
    }

    static func timelineQuery(nodeID: String, cursor: String? = nil) -> String {
        let escapedNodeID = escapeGraphQL(nodeID)
        let after = cursor.map { ", after: \"\(escapeGraphQL($0))\"" } ?? ""
        return """
        {
          node(id: "\(escapedNodeID)") {
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
              reviewRequests(first: 20) {
                nodes {
                  requestedReviewer {
                    __typename
                    ... on User { login avatarUrl }
                    ... on Team { name avatarUrl }
                  }
                }
              }
              reviews(last: 50) {
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
                        nodes {
                          __typename
                          ... on CheckRun {
                            name
                            status
                            conclusion
                            detailsUrl
                            startedAt
                            isRequired(pullRequestId: "\(escapedNodeID)")
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
        let escapedNodeID = escapeGraphQL(nodeID)
        let escapedCursor = escapeGraphQL(cursor)
        return """
        {
          node(id: "\(escapedNodeID)") {
            ... on PullRequest {
              commits(last: 1) {
                nodes {
                  commit {
                    statusCheckRollup {
                      contexts(first: 100, after: "\(escapedCursor)") {
                        nodes {
                          __typename
                          ... on CheckRun {
                            name
                            status
                            conclusion
                            detailsUrl
                            startedAt
                            isRequired(pullRequestId: "\(escapedNodeID)")
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

    /// Both mutations are aliased to `payload` so one response type decodes either.
    static func setDraftMutation(pullRequestID: String, isDraft: Bool) -> String {
        let mutationName = isDraft ? "convertPullRequestToDraft" : "markPullRequestReadyForReview"
        return """
        mutation {
          payload: \(mutationName)(input: {pullRequestId: "\(escapeGraphQL(pullRequestID))"}) {
            pullRequest {
              isDraft
            }
          }
        }
        """
    }
}
