import Testing
import Foundation
@testable import PullRequestPilot

@Suite("GitHubGraphQL")
struct GitHubGraphQLTests {

    /// The JSON body GitHub receives.
    private func body(_ request: GraphQLRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    private func variables(_ request: GraphQLRequest) throws -> [String: Any] {
        let body = try body(request)
        return try #require(body["variables"] as? [String: Any])
    }

    // MARK: - Variables, not interpolation

    @Test("user input travels as variables and never enters the document", arguments: [
        #"label:"bug fix""#,
        #"path:src\main"#,
        "line one\nline two",
        #"") { viewer { login } } #"#,
    ])
    func userInputIsAVariable(searchText: String) throws {
        let request = GitHubGraphQL.searchQuery(query: searchText, cursor: "cursor\"1")
        #expect(!request.query.contains(searchText))
        #expect(!request.query.contains("cursor\"1"))
        let variables = try variables(request)
        #expect(variables["query"] as? String == searchText)
        #expect(variables["cursor"] as? String == "cursor\"1")
    }

    @Test("a first page sends a null cursor and the page size")
    func searchFirstPage() throws {
        let variables = try variables(GitHubGraphQL.searchQuery(query: "is:open"))
        #expect(variables["cursor"] is NSNull)
        #expect(variables["pageSize"] as? Int == Constants.App.searchPageSize)
        #expect(variables["query"] as? String == "is:open")
    }

    @Test("the search document declares and uses its variables")
    func searchDocumentUsesVariables() {
        let document = GitHubGraphQL.searchQuery(query: "is:pr").query
        #expect(document.contains("query SearchPullRequests($query: String!, $pageSize: Int!, $cursor: String)"))
        #expect(document.contains("search(query: $query, type: ISSUE, first: $pageSize, after: $cursor)"))
    }

    // The GitHub search uses `type: ISSUE` which returns both Issues and PRs.
    // This is intentional: the app can be used to track issues too — do NOT
    // auto-prepend `is:pr` to user queries.
    @Test("searchQuery sends the user's query verbatim")
    func searchQueryDoesNotInjectIsPR() throws {
        let request = GitHubGraphQL.searchQuery(query: "is:open author:@me")
        let variables = try variables(request)
        #expect(variables["query"] as? String == "is:open author:@me")
        #expect(!request.query.contains("is:pr"))
    }

    @Test("timeline and checks requests send the pull request ID and cursor")
    func timelineAndChecksVariables() throws {
        let timeline = try variables(GitHubGraphQL.timelineQuery(nodeID: "PR_abc", cursor: "c1"))
        #expect(timeline["id"] as? String == "PR_abc")
        #expect(timeline["cursor"] as? String == "c1")
        let firstPage = try variables(GitHubGraphQL.timelineQuery(nodeID: "PR_abc"))
        #expect(firstPage["cursor"] is NSNull)

        let checks = try variables(GitHubGraphQL.checksQuery(nodeID: "PR_abc", cursor: "c2"))
        #expect(checks["id"] as? String == "PR_abc")
        #expect(checks["cursor"] as? String == "c2")
    }

    @Test("both check queries share one selection of check fields")
    func checkSelectionIsShared() {
        let timeline = GitHubGraphQL.timelineQuery(nodeID: "PR_1").query
        let checks = GitHubGraphQL.checksQuery(nodeID: "PR_1", cursor: "c1").query
        for document in [timeline, checks] {
            #expect(document.contains("...CheckContexts"))
            #expect(document.contains("fragment CheckContexts on StatusCheckRollupContextConnection"))
            #expect(document.contains("isRequired(pullRequestId: $id)"))
        }
        #expect(checks.contains("contexts(first: 100, after: $cursor)"))
    }

    @Test("equal requests are equal, so concurrent callers share one fetch")
    func requestsAreHashable() {
        #expect(GitHubGraphQL.searchQuery(query: "is:pr", cursor: "a") == GitHubGraphQL.searchQuery(query: "is:pr", cursor: "a"))
        #expect(GitHubGraphQL.searchQuery(query: "is:pr", cursor: "a") != GitHubGraphQL.searchQuery(query: "is:pr", cursor: "b"))
    }

    // MARK: - Selections

    @Test("setDraftMutation converts to draft under the payload alias")
    func setDraftMutationToDraft() throws {
        let mutation = GitHubGraphQL.setDraftMutation(pullRequestID: "PR_kwDO42", isDraft: true)
        #expect(mutation.query.contains("payload: convertPullRequestToDraft(input: {pullRequestId: $id})"))
        #expect(!mutation.query.contains("markPullRequestReadyForReview"))
        #expect(mutation.query.contains("isDraft"))
        let variables = try variables(mutation)
        #expect(variables["id"] as? String == "PR_kwDO42")
    }

    @Test("setDraftMutation marks ready for review under the payload alias")
    func setDraftMutationReadyForReview() {
        let mutation = GitHubGraphQL.setDraftMutation(pullRequestID: "PR_kwDO42", isDraft: false)
        #expect(mutation.query.contains("payload: markPullRequestReadyForReview(input: {pullRequestId: $id})"))
        #expect(!mutation.query.contains("convertPullRequestToDraft"))
    }

    @Test("searchQuery selects __typename outside the PR fragment so issues can be counted")
    func searchQuerySelectsNodeTypename() throws {
        let query = GitHubGraphQL.searchQuery(query: "is:pr").query
        let nodes = try #require(query.range(of: "nodes {"))
        let fragment = try #require(query.range(of: "... on PullRequest {"))
        let typename = try #require(query.range(of: "__typename", range: nodes.upperBound..<query.endIndex))
        #expect(typename.lowerBound < fragment.lowerBound)
    }

    @Test("searchQuery fetches fork status, author type and the newest review threads")
    func searchQueryFetchesForkAndAuthorType() throws {
        let query = GitHubGraphQL.searchQuery(query: "is:pr").query
        #expect(query.contains("isCrossRepository"))
        #expect(query.contains("reviewThreads(last: 100)"))
        let authorOpen = try #require(query.range(of: "author {"))
        let authorClose = try #require(query.range(of: "}", range: authorOpen.upperBound..<query.endIndex))
        #expect(query[authorOpen.upperBound..<authorClose.lowerBound].contains("__typename"))
    }

    @Test("searchQuery includes required fields")
    func searchQueryIncludesFields() {
        let query = GitHubGraphQL.searchQuery(query: "is:pr").query
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

    @Test("timelineQuery fetches the per-user review rollups, PR author and bot reviewers")
    func timelineQueryFetchesReviewRollups() {
        let query = GitHubGraphQL.timelineQuery(nodeID: "PR_1").query
        #expect(query.contains("latestOpinionatedReviews(first: 100)"))
        #expect(query.contains("latestReviews(first: 100)"))
        #expect(!query.contains("reviews(last:"))
        #expect(query.contains("author { login }"))
        #expect(query.contains("... on Bot { login avatarUrl }"))
        #expect(query.contains("... on Mannequin { login avatarUrl }"))
    }

    @Test("timelineQuery includes all event types")
    func timelineQueryIncludesAllEventTypes() {
        let query = GitHubGraphQL.timelineQuery(nodeID: "PR_1").query
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

    @Test("checksQuery includes check run fields")
    func checksQueryIncludesFields() {
        let query = GitHubGraphQL.checksQuery(nodeID: "PR_1", cursor: "c1").query
        let expectedFields = ["name", "status", "conclusion", "detailsUrl", "isRequired", "context", "state", "targetUrl", "__typename", "statusCheckRollup", "pageInfo", "hasNextPage", "endCursor"]
        for field in expectedFields {
            #expect(query.contains(field), "Missing field: \(field)")
        }
    }

    @Test("viewerQuery requests viewer login")
    func viewerQueryContent() throws {
        let query = GitHubGraphQL.viewerQuery.query
        #expect(query.contains("viewer"))
        #expect(query.contains("login"))
        let variables = try variables(GitHubGraphQL.viewerQuery)
        #expect(variables.isEmpty)
    }
}
