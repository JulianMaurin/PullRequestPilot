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

    static let viewerQuery = """
    {
      viewer {
        login
      }
    }
    """
}
