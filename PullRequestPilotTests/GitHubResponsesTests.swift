import Testing
import Foundation
@testable import PullRequestPilot

@Suite("GitHubResponses DTO")
struct GitHubResponsesTests {

    // MARK: - JSON Decoding

    @Test("PullRequestNode decodes from valid JSON")
    func decodesValidJSON() throws {
        let json = makeFullPRNodeJSON()
        let data = Data(json.utf8)
        let node = try JSONDecoder().decode(PullRequestNode.self, from: data)

        #expect(node.id == "PR_kwDOTest")
        #expect(node.number == 42)
        #expect(node.title == "Fix the thing")
        #expect(node.state == "OPEN")
        #expect(node.isDraft == false)
        #expect(node.additions == 10)
        #expect(node.deletions == 3)
        #expect(node.baseRefName == "main")
        #expect(node.headRefName == "fix/thing")
        #expect(node.headRefOid == "abc123def")
        #expect(node.repository.nameWithOwner == "owner/repo")
        #expect(node.author?.login == "octocat")
    }

    // MARK: - toDomain()

    @Test("toDomain maps all fields correctly")
    func toDomainMapsAllFields() throws {
        let json = makeFullPRNodeJSON()
        let data = Data(json.utf8)
        let node = try JSONDecoder().decode(PullRequestNode.self, from: data)

        let pr = try #require(node.toDomain())
        #expect(pr.number == 42)
        #expect(pr.title == "Fix the thing")
        #expect(pr.state == .open)
        #expect(pr.isDraft == false)
        #expect(pr.additions == 10)
        #expect(pr.deletions == 3)
        #expect(pr.repository.nameWithOwner == "owner/repo")
        #expect(pr.author.login == "octocat")
        #expect(pr.baseRefName == "main")
        #expect(pr.headRefName == "fix/thing")
        #expect(pr.headCommitSha == "abc123def")
        #expect(pr.checkStatus == .success)
        #expect(pr.reviewDecision == .reviewRequired)
    }

    @Test("toDomain returns nil for invalid dates (URL is always parseable by Foundation)")
    func toDomainInvalidInput() throws {
        // Foundation's URL(string:) is very permissive, so we test invalid dates instead
        let json = makeFullPRNodeJSON(createdAt: "garbage", updatedAt: "garbage")
        let data = Data(json.utf8)
        let node = try JSONDecoder().decode(PullRequestNode.self, from: data)
        #expect(node.toDomain() == nil)
    }

    @Test("toDomain handles dates without fractional seconds")
    func toDomainDatesFallbackFormatter() throws {
        let json = makeFullPRNodeJSON(
            createdAt: "2024-01-15T10:30:00Z",
            updatedAt: "2024-01-16T14:00:00Z"
        )
        let data = Data(json.utf8)
        let node = try JSONDecoder().decode(PullRequestNode.self, from: data)
        _ = try #require(node.toDomain())
    }

    @Test("toDomain uses 'ghost' when author is null")
    func toDomainNullAuthor() throws {
        let json = makeFullPRNodeJSON(authorJSON: "null")
        let data = Data(json.utf8)
        let node = try JSONDecoder().decode(PullRequestNode.self, from: data)
        let pr = try #require(node.toDomain())
        #expect(pr.author.login == "ghost")
    }

    @Test("toDomain counts unresolved threads")
    func toDomainUnresolvedThreads() throws {
        let threadsJSON = """
        {"totalCount": 3, "nodes": [
            {"isResolved": true},
            {"isResolved": false},
            {"isResolved": false}
        ]}
        """
        let json = makeFullPRNodeJSON(reviewThreadsJSON: threadsJSON)
        let data = Data(json.utf8)
        let node = try JSONDecoder().decode(PullRequestNode.self, from: data)
        let pr = try #require(node.toDomain())

        #expect(pr.totalThreads == 3)
        #expect(pr.unresolvedThreads == 2)
    }

    @Test("toDomain maps labels")
    func toDomainMapsLabels() throws {
        let labelsJSON = """
        {"nodes": [
            {"name": "bug", "color": "d73a4a"},
            {"name": "priority", "color": "0075ca"}
        ]}
        """
        let json = makeFullPRNodeJSON(labelsJSON: labelsJSON)
        let data = Data(json.utf8)
        let node = try JSONDecoder().decode(PullRequestNode.self, from: data)
        let pr = try #require(node.toDomain())

        #expect(pr.labels.count == 2)
        #expect(pr.labels[0].name == "bug")
        #expect(pr.labels[0].color == "d73a4a")
    }

    @Test("toDomain maps latest reviews")
    func toDomainMapsReviews() throws {
        let reviewsJSON = """
        {"nodes": [
            {"author": {"login": "alice"}, "state": "APPROVED"},
            {"author": {"login": "bob"}, "state": "CHANGES_REQUESTED"},
            {"author": null, "state": "COMMENTED"}
        ]}
        """
        let json = makeFullPRNodeJSON(latestReviewsJSON: reviewsJSON)
        let data = Data(json.utf8)
        let node = try JSONDecoder().decode(PullRequestNode.self, from: data)
        let pr = try #require(node.toDomain())

        #expect(pr.latestReviews.count == 2)
        #expect(pr.latestReviews[0].login == "alice")
        #expect(pr.latestReviews[0].state == .approved)
        #expect(pr.latestReviews[1].login == "bob")
        #expect(pr.latestReviews[1].state == .changesRequested)
    }

    @Test("toDomain defaults to .open for unknown state")
    func toDomainUnknownState() throws {
        let json = makeFullPRNodeJSON(state: "UNKNOWN_STATE")
        let data = Data(json.utf8)
        let node = try JSONDecoder().decode(PullRequestNode.self, from: data)
        let pr = node.toDomain()
        #expect(pr?.state == .open)
    }

    @Test("toDomain maps nil reviewDecision")
    func toDomainNilReviewDecision() throws {
        let json = makeFullPRNodeJSON(reviewDecision: "null")
        let data = Data(json.utf8)
        let node = try JSONDecoder().decode(PullRequestNode.self, from: data)
        let pr = node.toDomain()
        #expect(pr?.reviewDecision == nil)
    }

    // MARK: - Timeline / LastActivity

    @Test("toDomain maps IssueComment activity")
    func activityIssueComment() throws {
        let timelineJSON = makeTimelineJSON(typename: "IssueComment", authorField: "author")
        let json = makeFullPRNodeJSON(timelineJSON: timelineJSON)
        let data = Data(json.utf8)
        let node = try JSONDecoder().decode(PullRequestNode.self, from: data)
        let pr = try #require(node.toDomain())

        let activity = try #require(pr.lastActivity)
        #expect(activity.kind == .comment)
        #expect(activity.actor?.login == "reviewer")
    }

    @Test("toDomain maps PullRequestReview with APPROVED state")
    func activityReviewApproved() throws {
        let timelineJSON = makeTimelineJSON(typename: "PullRequestReview", authorField: "author", state: "APPROVED")
        let json = makeFullPRNodeJSON(timelineJSON: timelineJSON)
        let data = Data(json.utf8)
        let node = try JSONDecoder().decode(PullRequestNode.self, from: data)
        let pr = try #require(node.toDomain())
        let activity = try #require(pr.lastActivity)
        #expect(activity.kind == .review(.approved))
    }

    @Test("toDomain maps PullRequestReview with CHANGES_REQUESTED state")
    func activityReviewChangesRequested() throws {
        let timelineJSON = makeTimelineJSON(typename: "PullRequestReview", authorField: "author", state: "CHANGES_REQUESTED")
        let json = makeFullPRNodeJSON(timelineJSON: timelineJSON)
        let data = Data(json.utf8)
        let node = try JSONDecoder().decode(PullRequestNode.self, from: data)
        let pr = try #require(node.toDomain())
        let activity = try #require(pr.lastActivity)
        #expect(activity.kind == .review(.changesRequested))
    }

    @Test("toDomain maps PullRequestReview with COMMENTED state as review(nil)")
    func activityReviewCommented() throws {
        let timelineJSON = makeTimelineJSON(typename: "PullRequestReview", authorField: "author", state: "COMMENTED")
        let json = makeFullPRNodeJSON(timelineJSON: timelineJSON)
        let data = Data(json.utf8)
        let node = try JSONDecoder().decode(PullRequestNode.self, from: data)
        let pr = try #require(node.toDomain())
        let activity = try #require(pr.lastActivity)
        #expect(activity.kind == .review(nil))
    }

    @Test("toDomain maps MergedEvent activity")
    func activityMergedEvent() throws {
        let timelineJSON = makeTimelineJSON(typename: "MergedEvent", authorField: "actor")
        let json = makeFullPRNodeJSON(timelineJSON: timelineJSON)
        let data = Data(json.utf8)
        let node = try JSONDecoder().decode(PullRequestNode.self, from: data)
        let pr = try #require(node.toDomain())
        let activity = try #require(pr.lastActivity)
        #expect(activity.kind == .merged)
        #expect(activity.actor?.login == "reviewer")
    }

    @Test("toDomain maps ClosedEvent activity")
    func activityClosedEvent() throws {
        let timelineJSON = makeTimelineJSON(typename: "ClosedEvent", authorField: "actor")
        let json = makeFullPRNodeJSON(timelineJSON: timelineJSON)
        let data = Data(json.utf8)
        let node = try JSONDecoder().decode(PullRequestNode.self, from: data)
        let pr = try #require(node.toDomain())
        let activity = try #require(pr.lastActivity)
        #expect(activity.kind == .closed)
    }

    @Test("toDomain maps HeadRefForcePushedEvent activity")
    func activityForcePushed() throws {
        let timelineJSON = makeTimelineJSON(typename: "HeadRefForcePushedEvent", authorField: "actor")
        let json = makeFullPRNodeJSON(timelineJSON: timelineJSON)
        let data = Data(json.utf8)
        let node = try JSONDecoder().decode(PullRequestNode.self, from: data)
        let pr = try #require(node.toDomain())
        let activity = try #require(pr.lastActivity)
        #expect(activity.kind == .forcePushed)
    }

    @Test("toDomain maps PullRequestCommit activity")
    func activityCommit() throws {
        let timelineJSON = """
        {"nodes": [{
            "__typename": "PullRequestCommit",
            "createdAt": null,
            "author": null,
            "actor": null,
            "state": null,
            "commit": {
                "committedDate": "2024-01-15T10:30:00.000Z",
                "author": {
                    "user": {"login": "committer", "avatarUrl": null}
                }
            }
        }]}
        """
        let json = makeFullPRNodeJSON(timelineJSON: timelineJSON)
        let data = Data(json.utf8)
        let node = try JSONDecoder().decode(PullRequestNode.self, from: data)
        let pr = try #require(node.toDomain())
        let activity = try #require(pr.lastActivity)
        #expect(activity.kind == .committed)
        #expect(activity.actor?.login == "committer")
    }

    @Test("toDomain returns nil lastActivity for unknown typename")
    func activityUnknownType() throws {
        let timelineJSON = """
        {"nodes": [{
            "__typename": "UnknownEvent",
            "createdAt": "2024-01-15T10:30:00.000Z",
            "author": null,
            "actor": null,
            "state": null,
            "commit": null
        }]}
        """
        let json = makeFullPRNodeJSON(timelineJSON: timelineJSON)
        let data = Data(json.utf8)
        let node = try JSONDecoder().decode(PullRequestNode.self, from: data)
        let pr = try #require(node.toDomain())

        #expect(pr.lastActivity == nil)
    }

    @Test("toDomain returns nil lastActivity when timeline is empty")
    func activityEmptyTimeline() throws {
        let json = makeFullPRNodeJSON(timelineJSON: #"{"nodes": []}"#)
        let data = Data(json.utf8)
        let node = try JSONDecoder().decode(PullRequestNode.self, from: data)
        let pr = try #require(node.toDomain())

        #expect(pr.lastActivity == nil)
    }

    // MARK: - ViewerData

    @Test("ViewerData decodes correctly")
    func viewerDataDecoding() throws {
        let json = #"{"viewer": {"login": "octocat"}}"#
        let data = Data(json.utf8)
        let viewerData = try JSONDecoder().decode(ViewerData.self, from: data)
        #expect(viewerData.viewer.login == "octocat")
    }

    // MARK: - GraphQLResponse

    @Test("GraphQLResponse decodes data and errors")
    func graphQLResponseDecoding() throws {
        let json = #"{"data": {"viewer": {"login": "test"}}, "errors": [{"message": "warning"}]}"#
        let data = Data(json.utf8)
        let response = try JSONDecoder().decode(GraphQLResponse<ViewerData>.self, from: data)
        #expect(response.data?.viewer.login == "test")
        #expect(response.errors?.count == 1)
        #expect(response.errors?.first?.message == "warning")
    }

    @Test("GraphQLResponse decodes with nil data")
    func graphQLResponseNilData() throws {
        let json = #"{"data": null, "errors": [{"message": "bad"}]}"#
        let data = Data(json.utf8)
        let response = try JSONDecoder().decode(GraphQLResponse<ViewerData>.self, from: data)
        #expect(response.data == nil)
        #expect(response.errors?.first?.message == "bad")
    }

    // MARK: - PageInfo

    @Test("PageInfo decodes correctly")
    func pageInfoDecoding() throws {
        let json = #"{"hasNextPage": true, "endCursor": "Y3Vyc29y"}"#
        let data = Data(json.utf8)
        let pageInfo = try JSONDecoder().decode(PageInfo.self, from: data)
        #expect(pageInfo.hasNextPage == true)
        #expect(pageInfo.endCursor == "Y3Vyc29y")
    }

    // MARK: - Helpers

    private func makeTimelineJSON(typename: String, authorField: String, state: String? = nil) -> String {
        let stateVal = state.map { #""\#($0)""# } ?? "null"
        let authorVal = #"{"login": "reviewer", "avatarUrl": null}"#
        let authorKey = authorField == "actor" ? "actor" : "author"
        let otherKey = authorField == "actor" ? "author" : "actor"
        return """
        {"nodes": [{
            "__typename": "\(typename)",
            "createdAt": "2024-01-15T10:30:00.000Z",
            "\(authorKey)": \(authorVal),
            "\(otherKey)": null,
            "state": \(stateVal),
            "commit": null
        }]}
        """
    }

    @Test("toDomain marks a Bot author so filters can use author:app/")
    func toDomainMapsBotAuthor() throws {
        let json = makeFullPRNodeJSON(authorJSON: #"{"__typename": "Bot", "login": "dependabot", "avatarUrl": null}"#)
        let node = try JSONDecoder().decode(PullRequestNode.self, from: Data(json.utf8))
        let pr = try #require(node.toDomain())
        #expect(pr.author.isBot)
        #expect(pr.author.searchQualifierValue == "app/dependabot")
    }

    @Test("toDomain keeps a User author as a plain login")
    func toDomainMapsUserAuthor() throws {
        let json = makeFullPRNodeJSON(authorJSON: #"{"__typename": "User", "login": "octocat", "avatarUrl": null}"#)
        let node = try JSONDecoder().decode(PullRequestNode.self, from: Data(json.utf8))
        let pr = try #require(node.toDomain())
        #expect(!pr.author.isBot)
        #expect(pr.author.searchQualifierValue == "octocat")
    }

    @Test("toDomain maps isCrossRepository, defaulting to false when absent")
    func toDomainMapsCrossRepository() throws {
        let fork = try JSONDecoder().decode(PullRequestNode.self, from: Data(makeFullPRNodeJSON(isCrossRepository: true).utf8))
        #expect(try #require(fork.toDomain()).isCrossRepository)

        let legacyJSON = makeFullPRNodeJSON().replacingOccurrences(of: #""isCrossRepository": false,"#, with: "")
        let legacy = try JSONDecoder().decode(PullRequestNode.self, from: Data(legacyJSON.utf8))
        #expect(try #require(legacy.toDomain()).isCrossRepository == false)
    }

    private func makeFullPRNodeJSON(
        url: String = "https://github.com/owner/repo/pull/42",
        createdAt: String = "2024-01-15T10:30:00.000Z",
        updatedAt: String = "2024-01-16T14:00:00.000Z",
        state: String = "OPEN",
        reviewDecision: String = #""REVIEW_REQUIRED""#,
        authorJSON: String = #"{"login": "octocat", "avatarUrl": "https://avatars.githubusercontent.com/u/1"}"#,
        reviewThreadsJSON: String = #"{"totalCount": 0, "nodes": []}"#,
        latestReviewsJSON: String = #"{"nodes": []}"#,
        labelsJSON: String = #"{"nodes": []}"#,
        timelineJSON: String = #"{"nodes": []}"#,
        isCrossRepository: Bool = false
    ) -> String {
        """
        {
            "id": "PR_kwDOTest",
            "number": 42,
            "title": "Fix the thing",
            "url": "\(url)",
            "createdAt": "\(createdAt)",
            "updatedAt": "\(updatedAt)",
            "additions": 10,
            "deletions": 3,
            "state": "\(state)",
            "isDraft": false,
            "reviewDecision": \(reviewDecision),
            "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "SUCCESS"}}}]},
            "baseRefName": "main",
            "headRefName": "fix/thing",
            "headRefOid": "abc123def",
            "isCrossRepository": \(isCrossRepository),
            "repository": {"nameWithOwner": "owner/repo"},
            "author": \(authorJSON),
            "reviewThreads": \(reviewThreadsJSON),
            "latestReviews": \(latestReviewsJSON),
            "labels": \(labelsJSON),
            "timelineItems": \(timelineJSON)
        }
        """
    }
}
