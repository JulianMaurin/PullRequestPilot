import Foundation

enum GitHubGraphQL {
    static func reviewRequestedQuery(cursor: String? = nil) -> String {
        let after = cursor.map { ", after: \"\($0)\"" } ?? ""
        return """
        {
          search(query: "is:pr is:open review-requested:@me archived:false", type: ISSUE, first: 50\(after)) {
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
                isDraft
                reviewDecision
                repository {
                  nameWithOwner
                }
                author {
                  login
                  avatarUrl
                }
                labels(first: 10) {
                  nodes {
                    name
                    color
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
