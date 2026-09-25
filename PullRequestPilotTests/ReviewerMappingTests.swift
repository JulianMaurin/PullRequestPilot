import Testing
import Foundation
@testable import PullRequestPilot

@Suite("TimelinePullRequestNode.toReviewers")
struct ReviewerMappingTests {

    private func makeReviewNode(login: String, state: String, avatarUrl: String? = nil) -> ReviewNode {
        ReviewNode(
            author: ReviewNode.ReviewAuthorNode(login: login, avatarUrl: avatarUrl),
            state: state
        )
    }

    private func makeRequestNode(typename: String = "User", login: String? = nil, name: String? = nil, avatarUrl: String? = nil) -> ReviewRequestNode {
        ReviewRequestNode(
            requestedReviewer: RequestedReviewerNode(
                typename: typename,
                login: login,
                name: name,
                avatarUrl: avatarUrl
            )
        )
    }

    private func makeNode(
        opinionated: [ReviewNode] = [],
        latest: [ReviewNode] = [],
        requests: [ReviewRequestNode] = [],
        prAuthor: String? = nil
    ) -> TimelinePullRequestNode {
        TimelinePullRequestNode(
            timelineItems: nil,
            reviewRequests: requests.isEmpty ? nil : ReviewRequestsConnection(nodes: requests),
            latestOpinionatedReviews: opinionated.isEmpty ? nil : ReviewsConnection(nodes: opinionated),
            latestReviews: latest.isEmpty ? nil : ReviewsConnection(nodes: latest),
            commits: nil,
            author: prAuthor.map { PullRequestNode.AuthorNode(login: $0, avatarUrl: nil) }
        )
    }

    // MARK: - Basic Mapping

    @Test("empty reviews and requests returns empty")
    func emptyReturnsEmpty() {
        #expect(makeNode().toReviewers().isEmpty)
    }

    @Test("single approved reviewer maps correctly")
    func singleApprovedReviewer() {
        let reviewers = makeNode(opinionated: [makeReviewNode(login: "alice", state: "APPROVED")]).toReviewers()
        #expect(reviewers.count == 1)
        #expect(reviewers[0].displayName == "alice")
        #expect(reviewers[0].state == .approved)
        #expect(!reviewers[0].isTeam)
    }

    @Test("review states map; opinionated reviewers come before comment-only ones")
    func multipleStates() {
        let reviewers = makeNode(
            opinionated: [
                makeReviewNode(login: "alice", state: "APPROVED"),
                makeReviewNode(login: "bob", state: "CHANGES_REQUESTED"),
                makeReviewNode(login: "dave", state: "DISMISSED"),
            ],
            latest: [makeReviewNode(login: "carol", state: "COMMENTED")]
        ).toReviewers()
        #expect(reviewers.map(\.displayName) == ["alice", "bob", "dave", "carol"])
        #expect(reviewers.map(\.state) == [.approved, .changesRequested, .dismissed, .commented])
    }

    // MARK: - GitHub's rollup rules

    @Test("a later thread reply does not demote an approval")
    func commentDoesNotDemoteApproval() {
        let reviewers = makeNode(
            opinionated: [makeReviewNode(login: "alice", state: "APPROVED")],
            latest: [makeReviewNode(login: "alice", state: "COMMENTED")]
        ).toReviewers()
        #expect(reviewers.count == 1)
        #expect(reviewers[0].state == .approved)
    }

    @Test("a later thread reply does not hide a change request")
    func commentDoesNotDemoteChangeRequest() {
        let reviewers = makeNode(
            opinionated: [makeReviewNode(login: "bob", state: "CHANGES_REQUESTED")],
            latest: [makeReviewNode(login: "bob", state: "COMMENTED")]
        ).toReviewers()
        #expect(reviewers.map(\.state) == [.changesRequested])
    }

    @Test("a comment-only reviewer is listed as commented")
    func commentOnlyReviewer() {
        let reviewers = makeNode(latest: [makeReviewNode(login: "carol", state: "COMMENTED")]).toReviewers()
        #expect(reviewers.map(\.displayName) == ["carol"])
        #expect(reviewers.map(\.state) == [.commented])
    }

    @Test("the PR author's own replies don't make them a reviewer")
    func authorIsNotAReviewer() {
        let reviewers = makeNode(
            latest: [
                makeReviewNode(login: "author", state: "COMMENTED"),
                makeReviewNode(login: "carol", state: "COMMENTED"),
            ],
            prAuthor: "author"
        ).toReviewers()
        #expect(reviewers.map(\.displayName) == ["carol"])
    }

    @Test("a re-requested reviewer shows as awaiting review, not their old verdict")
    func reRequestedReviewerIsPending() {
        let reviewers = makeNode(
            opinionated: [makeReviewNode(login: "alice", state: "CHANGES_REQUESTED")],
            requests: [makeRequestNode(login: "alice")]
        ).toReviewers()
        #expect(reviewers.count == 1)
        #expect(reviewers[0].displayName == "alice")
        #expect(reviewers[0].state == .pending)
    }

    // MARK: - Requested Reviewers

    @Test("pending reviewer added from requests")
    func pendingReviewerFromRequests() {
        let reviewers = makeNode(requests: [makeRequestNode(login: "alice")]).toReviewers()
        #expect(reviewers.count == 1)
        #expect(reviewers[0].state == .pending)
        #expect(reviewers[0].displayName == "alice")
    }

    @Test("team reviewer has isTeam set and uses name")
    func teamReviewer() {
        let reviewers = makeNode(requests: [makeRequestNode(typename: "Team", name: "backend-team")]).toReviewers()
        #expect(reviewers.count == 1)
        #expect(reviewers[0].isTeam)
        #expect(reviewers[0].displayName == "backend-team")
        #expect(reviewers[0].state == .pending)
    }

    @Test("bot reviewers keep their login and stay distinct")
    func botReviewers() {
        let reviewers = makeNode(requests: [
            makeRequestNode(typename: "Bot", login: "copilot-pull-request-reviewer"),
            makeRequestNode(typename: "Bot", login: "coderabbitai"),
        ]).toReviewers()
        #expect(reviewers.map(\.displayName) == ["copilot-pull-request-reviewer", "coderabbitai"])
        #expect(reviewers.allSatisfy { !$0.isTeam && $0.state == .pending })
    }

    @Test("unknown review state is skipped")
    func unknownStateIsSkipped() {
        #expect(makeNode(latest: [makeReviewNode(login: "alice", state: "UNKNOWN_STATE")]).toReviewers().isEmpty)
    }

    @Test("review with nil author is skipped")
    func nilAuthorSkipped() {
        let node = makeNode(latest: [ReviewNode(author: nil, state: "APPROVED")])
        #expect(node.toReviewers().isEmpty)
    }
}
