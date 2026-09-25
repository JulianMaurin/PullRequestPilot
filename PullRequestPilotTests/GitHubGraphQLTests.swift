import Testing
import Foundation
@testable import PullRequestPilot

@Suite("GitHubGraphQL")
struct GitHubGraphQLTests {

    @Test("setDraftMutation converts to draft under the payload alias")
    func setDraftMutationToDraft() {
        let mutation = GitHubGraphQL.setDraftMutation(pullRequestID: "PR_kwDO42", isDraft: true)
        #expect(mutation.contains(#"payload: convertPullRequestToDraft(input: {pullRequestId: "PR_kwDO42"})"#))
        #expect(!mutation.contains("markPullRequestReadyForReview"))
        #expect(mutation.contains("isDraft"))
    }

    @Test("setDraftMutation marks ready for review under the payload alias")
    func setDraftMutationReadyForReview() {
        let mutation = GitHubGraphQL.setDraftMutation(pullRequestID: "PR_kwDO42", isDraft: false)
        #expect(mutation.contains(#"payload: markPullRequestReadyForReview(input: {pullRequestId: "PR_kwDO42"})"#))
        #expect(!mutation.contains("convertPullRequestToDraft"))
    }

    @Test("setDraftMutation escapes the pull request ID")
    func setDraftMutationEscapesID() {
        let mutation = GitHubGraphQL.setDraftMutation(pullRequestID: "PR_\"x\"", isDraft: true)
        #expect(mutation.contains(#"pullRequestId: "PR_\"x\"""#))
    }

    @Test("searchQuery selects __typename outside the PR fragment so issues can be counted")
    func searchQuerySelectsNodeTypename() throws {
        let query = GitHubGraphQL.searchQuery(query: "is:pr")
        let nodes = try #require(query.range(of: "nodes {"))
        let fragment = try #require(query.range(of: "... on PullRequest {"))
        let typename = try #require(query.range(of: "__typename", range: nodes.upperBound..<query.endIndex))
        #expect(typename.lowerBound < fragment.lowerBound)
    }

    @Test("searchQuery fetches fork status, author type and the newest review threads")
    func searchQueryFetchesForkAndAuthorType() throws {
        let query = GitHubGraphQL.searchQuery(query: "is:pr")
        #expect(query.contains("isCrossRepository"))
        #expect(query.contains("reviewThreads(last: 100)"))
        let authorOpen = try #require(query.range(of: "author {"))
        let authorClose = try #require(query.range(of: "}", range: authorOpen.upperBound..<query.endIndex))
        #expect(query[authorOpen.upperBound..<authorClose.lowerBound].contains("__typename"))
    }

    @Test("timelineQuery fetches the per-user review rollups, PR author and bot reviewers")
    func timelineQueryFetchesReviewRollups() {
        let query = GitHubGraphQL.timelineQuery(nodeID: "PR_1")
        #expect(query.contains("latestOpinionatedReviews(first: 100)"))
        #expect(query.contains("latestReviews(first: 100)"))
        #expect(!query.contains("reviews(last:"))
        #expect(query.contains("author { login }"))
        #expect(query.contains("... on Bot { login avatarUrl }"))
        #expect(query.contains("... on Mannequin { login avatarUrl }"))
    }

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

    // The GitHub search uses `type: ISSUE` which returns both Issues and PRs.
    // Non-PR nodes are silently skipped by SearchResult's custom decoder.
    // This is intentional: the app can be used to track issues too — do NOT
    // auto-prepend `is:pr` to user queries.
    @Test("searchQuery preserves user query verbatim — does not inject is:pr")
    func searchQueryDoesNotInjectIsPR() {
        let query = GitHubGraphQL.searchQuery(query: "is:open author:@me")
        #expect(query.contains("is:open author:@me"))
        #expect(!query.contains("is:pr"))
    }

    // MARK: - Timeline Query

    @Test("timelineQuery includes nodeID")
    func timelineQueryIncludesNodeID() {
        let query = GitHubGraphQL.timelineQuery(nodeID: "PR_abc123")
        #expect(query.contains(#"node(id: "PR_abc123")"#))
    }

    @Test("timelineQuery without cursor omits after parameter")
    func timelineQueryNoCursor() {
        let query = GitHubGraphQL.timelineQuery(nodeID: "PR_1")
        #expect(!query.contains("after:"))
    }

    @Test("timelineQuery with cursor includes after parameter")
    func timelineQueryWithCursor() {
        let query = GitHubGraphQL.timelineQuery(nodeID: "PR_1", cursor: "cursor123")
        #expect(query.contains(#"after: "cursor123""#))
    }

    @Test("timelineQuery includes all event types")
    func timelineQueryIncludesAllEventTypes() {
        let query = GitHubGraphQL.timelineQuery(nodeID: "PR_1")
        let expectedTypes = [
            "ISSUE_COMMENT", "PULL_REQUEST_REVIEW", "MERGED_EVENT",
            "CLOSED_EVENT", "HEAD_REF_FORCE_PUSHED_EVENT", "PULL_REQUEST_COMMIT",
            "REOPENED_EVENT", "READY_FOR_REVIEW_EVENT", "CONVERT_TO_DRAFT_EVENT",
            "ASSIGNED_EVENT", "REVIEW_REQUESTED_EVENT",
        ]
        for eventType in expectedTypes {
            #expect(query.contains(eventType), "Missing event type: \(eventType)")
        }
    }

    // MARK: - Checks Query

    @Test("checksQuery includes nodeID and cursor")
    func checksQueryIncludesNodeIDAndCursor() {
        let query = GitHubGraphQL.checksQuery(nodeID: "PR_abc123", cursor: "cursor456")
        #expect(query.contains(#"node(id: "PR_abc123")"#))
        #expect(query.contains(#"after: "cursor456""#))
    }

    @Test("checksQuery includes check run fields")
    func checksQueryIncludesFields() {
        let query = GitHubGraphQL.checksQuery(nodeID: "PR_1", cursor: "c1")
        let expectedFields = ["name", "status", "conclusion", "detailsUrl", "isRequired", "context", "state", "targetUrl", "__typename", "statusCheckRollup", "pageInfo", "hasNextPage", "endCursor"]
        for field in expectedFields {
            #expect(query.contains(field), "Missing field: \(field)")
        }
    }

    @Test("checksQuery escapes special characters in nodeID")
    func checksQueryEscapesNodeID() {
        let query = GitHubGraphQL.checksQuery(nodeID: #"PR_"test""#, cursor: "c1")
        #expect(query.contains(#"PR_\"test\""#))
    }

    // MARK: - Viewer Query

    @Test("viewerQuery requests viewer login")
    func viewerQueryContent() {
        let query = GitHubGraphQL.viewerQuery
        #expect(query.contains("viewer"))
        #expect(query.contains("login"))
    }
}
