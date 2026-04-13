import Testing
import Foundation
@testable import PullRequestPilot

@Suite("Timeline DTO Mapping")
struct TimelineResponseMappingTests {

    private let validDate = "2024-01-15T10:30:00Z"

    private func makeNode(
        typename: String,
        createdAt: String? = nil,
        authorLogin: String? = "alice",
        actorLogin: String? = nil,
        state: String? = nil,
        body: String? = nil,
        commitDate: String? = nil,
        commitMessage: String? = nil,
        commitUserLogin: String? = nil,
        assigneeLogin: String? = nil,
        reviewerLogin: String? = nil,
        reviewerName: String? = nil
    ) -> TimelineItemDetailNode {
        let author = authorLogin.map { PullRequestNode.AuthorNode(login: $0, avatarUrl: nil) }
        let actor = actorLogin.map { PullRequestNode.AuthorNode(login: $0, avatarUrl: nil) }
        let commit = (commitDate != nil || commitMessage != nil) ? TimelineItemDetailNode.CommitDetailNode(
            committedDate: commitDate,
            message: commitMessage,
            author: commitUserLogin.map { .init(user: PullRequestNode.AuthorNode(login: $0, avatarUrl: nil)) }
        ) : nil
        let assignee = assigneeLogin.map { TimelineItemDetailNode.AssigneeNode(login: $0) }
        let reviewer = (reviewerLogin != nil || reviewerName != nil)
            ? TimelineItemDetailNode.RequestedReviewerNode(login: reviewerLogin, name: reviewerName)
            : nil

        return TimelineItemDetailNode(
            typename: typename,
            createdAt: createdAt,
            author: author,
            actor: actor,
            state: state,
            body: body,
            commit: commit,
            assignee: assignee,
            requestedReviewer: reviewer
        )
    }

    private func makeConnection(_ nodes: [TimelineItemDetailNode]) -> TimelineItemsConnection {
        TimelineItemsConnection(
            nodes: nodes,
            pageInfo: PageInfo(hasNextPage: false, endCursor: nil)
        )
    }

    // MARK: - Event Type Mapping

    @Test("maps IssueComment")
    func mapsIssueComment() {
        let connection = makeConnection([
            makeNode(typename: "IssueComment", createdAt: validDate, body: "looks good"),
        ])
        let events = connection.toDomain()
        #expect(events.count == 1)
        #expect(events[0].kind == .comment)
        #expect(events[0].actor?.login == "alice")
        #expect(events[0].body == "looks good")
    }

    @Test("maps PullRequestReview with APPROVED state")
    func mapsReviewApproved() {
        let connection = makeConnection([
            makeNode(typename: "PullRequestReview", createdAt: validDate, state: "APPROVED"),
        ])
        let events = connection.toDomain()
        #expect(events.count == 1)
        #expect(events[0].kind == .review(.approved))
    }

    @Test("maps PullRequestReview with CHANGES_REQUESTED state")
    func mapsReviewChangesRequested() {
        let connection = makeConnection([
            makeNode(typename: "PullRequestReview", createdAt: validDate, state: "CHANGES_REQUESTED"),
        ])
        let events = connection.toDomain()
        #expect(events[0].kind == .review(.changesRequested))
    }

    @Test("maps MergedEvent")
    func mapsMergedEvent() {
        let connection = makeConnection([
            makeNode(typename: "MergedEvent", createdAt: validDate, authorLogin: nil, actorLogin: "bob"),
        ])
        let events = connection.toDomain()
        #expect(events[0].kind == .merged)
        #expect(events[0].actor?.login == "bob")
    }

    @Test("maps ClosedEvent")
    func mapsClosedEvent() {
        let connection = makeConnection([
            makeNode(typename: "ClosedEvent", createdAt: validDate, authorLogin: nil, actorLogin: "bob"),
        ])
        let events = connection.toDomain()
        #expect(events[0].kind == .closed)
    }

    @Test("maps ReopenedEvent")
    func mapsReopenedEvent() {
        let connection = makeConnection([
            makeNode(typename: "ReopenedEvent", createdAt: validDate, authorLogin: nil, actorLogin: "bob"),
        ])
        let events = connection.toDomain()
        #expect(events[0].kind == .reopened)
    }

    @Test("maps HeadRefForcePushedEvent")
    func mapsForcePushed() {
        let connection = makeConnection([
            makeNode(typename: "HeadRefForcePushedEvent", createdAt: validDate, authorLogin: nil, actorLogin: "bob"),
        ])
        let events = connection.toDomain()
        #expect(events[0].kind == .forcePushed)
    }

    @Test("maps PullRequestCommit")
    func mapsCommit() {
        let connection = makeConnection([
            makeNode(
                typename: "PullRequestCommit",
                authorLogin: nil,
                commitDate: validDate,
                commitMessage: "fix bug",
                commitUserLogin: "alice"
            ),
        ])
        let events = connection.toDomain()
        #expect(events[0].kind == .commit(message: "fix bug"))
        #expect(events[0].actor?.login == "alice")
    }

    @Test("maps ReadyForReviewEvent")
    func mapsReadyForReview() {
        let connection = makeConnection([
            makeNode(typename: "ReadyForReviewEvent", createdAt: validDate, authorLogin: nil, actorLogin: "alice"),
        ])
        let events = connection.toDomain()
        #expect(events[0].kind == .readyForReview)
    }

    @Test("maps ConvertToDraftEvent")
    func mapsConvertToDraft() {
        let connection = makeConnection([
            makeNode(typename: "ConvertToDraftEvent", createdAt: validDate, authorLogin: nil, actorLogin: "alice"),
        ])
        let events = connection.toDomain()
        #expect(events[0].kind == .convertedToDraft)
    }

    @Test("maps AssignedEvent with assignee")
    func mapsAssignedEvent() {
        let connection = makeConnection([
            makeNode(typename: "AssignedEvent", createdAt: validDate, authorLogin: nil, actorLogin: "alice", assigneeLogin: "bob"),
        ])
        let events = connection.toDomain()
        #expect(events[0].kind == .assigned(assignee: "bob"))
    }

    @Test("maps ReviewRequestedEvent with user login")
    func mapsReviewRequestedUser() {
        let connection = makeConnection([
            makeNode(typename: "ReviewRequestedEvent", createdAt: validDate, authorLogin: nil, actorLogin: "alice", reviewerLogin: "bob"),
        ])
        let events = connection.toDomain()
        #expect(events[0].kind == .reviewRequested(reviewer: "bob"))
    }

    @Test("maps ReviewRequestedEvent with team name")
    func mapsReviewRequestedTeam() {
        let connection = makeConnection([
            makeNode(typename: "ReviewRequestedEvent", createdAt: validDate, authorLogin: nil, actorLogin: "alice", reviewerName: "backend-team"),
        ])
        let events = connection.toDomain()
        #expect(events[0].kind == .reviewRequested(reviewer: "backend-team"))
    }

    // MARK: - Edge Cases

    @Test("skips unknown typename")
    func skipsUnknownTypename() {
        let connection = makeConnection([
            makeNode(typename: "UnknownEvent", createdAt: validDate),
        ])
        let events = connection.toDomain()
        #expect(events.isEmpty)
    }

    @Test("skips node with missing date")
    func skipsMissingDate() {
        let connection = makeConnection([
            makeNode(typename: "IssueComment", createdAt: nil),
        ])
        let events = connection.toDomain()
        #expect(events.isEmpty)
    }

    @Test("handles date with fractional seconds")
    func handlesFractionalSeconds() {
        let connection = makeConnection([
            makeNode(typename: "IssueComment", createdAt: "2024-01-15T10:30:00.123Z"),
        ])
        let events = connection.toDomain()
        #expect(events.count == 1)
    }

    @Test("handles null actor")
    func handlesNullActor() {
        let connection = makeConnection([
            makeNode(typename: "MergedEvent", createdAt: validDate, authorLogin: nil, actorLogin: nil),
        ])
        let events = connection.toDomain()
        #expect(events.count == 1)
        #expect(events[0].actor == nil)
    }

    @Test("maps multiple events preserving order")
    func mapsMultipleEvents() {
        let connection = makeConnection([
            makeNode(typename: "IssueComment", createdAt: "2024-01-15T10:00:00Z"),
            makeNode(typename: "MergedEvent", createdAt: "2024-01-15T11:00:00Z", authorLogin: nil, actorLogin: "bob"),
        ])
        let events = connection.toDomain()
        #expect(events.count == 2)
        #expect(events[0].kind == .comment)
        #expect(events[1].kind == .merged)
    }

    // MARK: - PageInfo

    @Test("pageInfo with next page preserves cursor")
    func pageInfoPreservesCursor() {
        let connection = TimelineItemsConnection(
            nodes: [],
            pageInfo: PageInfo(hasNextPage: true, endCursor: "cursor_abc")
        )
        #expect(connection.pageInfo.hasNextPage == true)
        #expect(connection.pageInfo.endCursor == "cursor_abc")
    }
}
