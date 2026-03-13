import Testing
import Foundation
@testable import PullRequestPilot

@Suite("GitHubGraphQL")
struct GitHubGraphQLTests {

    @Test("searchQuery without cursor omits after parameter")
    func searchQueryNoCursor() {
        let query = GitHubGraphQL.searchQuery(query: "is:pr is:open")
        #expect(query.contains("is:pr is:open"))
        #expect(!query.contains("after:"))
        #expect(query.contains("first: 50"))
    }

    @Test("searchQuery with cursor includes after parameter")
    func searchQueryWithCursor() {
        let query = GitHubGraphQL.searchQuery(query: "is:pr", cursor: "abc123")
        #expect(query.contains(#"after: "abc123""#))
    }

    @Test("searchQuery escapes double quotes in query")
    func searchQueryEscapesQuotes() {
        let query = GitHubGraphQL.searchQuery(query: #"label:"bug fix""#)
        #expect(query.contains(#"label:\"bug fix\""#))
    }

    @Test("searchQuery escapes backslashes in query")
    func searchQueryEscapesBackslashes() {
        let query = GitHubGraphQL.searchQuery(query: #"path:src\main"#)
        #expect(query.contains(#"path:src\\main"#))
    }

    @Test("searchQuery includes required fields")
    func searchQueryIncludesFields() {
        let query = GitHubGraphQL.searchQuery(query: "is:pr")
        let expectedFields = [
            "id", "number", "title", "url", "createdAt", "updatedAt",
            "additions", "deletions", "state", "isDraft", "reviewDecision",
            "baseRefName", "headRefName", "headRefOid",
            "nameWithOwner", "login", "avatarUrl",
            "statusCheckRollup", "isResolved", "latestReviews",
            "pageInfo", "hasNextPage", "endCursor", "__typename",
        ]
        for field in expectedFields {
            #expect(query.contains(field), "Missing field: \(field)")
        }
    }

    @Test("viewerQuery requests viewer login")
    func viewerQueryContent() {
        let query = GitHubGraphQL.viewerQuery
        #expect(query.contains("viewer"))
        #expect(query.contains("login"))
    }
}
