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
                isDraft
                reviewDecision
                baseRefName
                headRefName
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
