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

    // MARK: - Basic Mapping

    @Test("empty reviews and requests returns empty")
    func emptyReturnsEmpty() {
        let node = TimelinePullRequestNode(timelineItems: nil, reviewRequests: nil, reviews: nil, commits: nil)
        let reviewers = node.toReviewers()
        #expect(reviewers.isEmpty)
    }

    @Test("single approved reviewer maps correctly")
    func singleApprovedReviewer() {
        let node = TimelinePullRequestNode(
            timelineItems: nil,
            reviewRequests: nil,
            reviews: ReviewsConnection(nodes: [makeReviewNode(login: "alice", state: "APPROVED")]),
            commits: nil
        )
        let reviewers = node.toReviewers()
        #expect(reviewers.count == 1)
        #expect(reviewers[0].displayName == "alice")
        #expect(reviewers[0].state == .approved)
        #expect(!reviewers[0].isTeam)
    }

    @Test("multiple review states mapped correctly")
    func multipleStates() {
        let node = TimelinePullRequestNode(
            timelineItems: nil,
            reviewRequests: nil,
            reviews: ReviewsConnection(nodes: [
                makeReviewNode(login: "alice", state: "APPROVED"),
                makeReviewNode(login: "bob", state: "CHANGES_REQUESTED"),
                makeReviewNode(login: "carol", state: "COMMENTED"),
                makeReviewNode(login: "dave", state: "DISMISSED"),
            ]),
            commits: nil
        )
        let reviewers = node.toReviewers()
        #expect(reviewers.count == 4)
        #expect(reviewers[0].state == .approved)
        #expect(reviewers[1].state == .changesRequested)
        #expect(reviewers[2].state == .commented)
        #expect(reviewers[3].state == .dismissed)
    }

    // MARK: - Deduplication

    @Test("latest review per author wins")
    func latestReviewWins() {
        let node = TimelinePullRequestNode(
            timelineItems: nil,
            reviewRequests: nil,
            reviews: ReviewsConnection(nodes: [
                makeReviewNode(login: "alice", state: "CHANGES_REQUESTED"),
                makeReviewNode(login: "alice", state: "APPROVED"),
            ]),
            commits: nil
        )
        let reviewers = node.toReviewers()
        #expect(reviewers.count == 1)
        #expect(reviewers[0].state == .approved)
    }

    @Test("author order is preserved (first appearance)")
    func authorOrderPreserved() {
        let node = TimelinePullRequestNode(
            timelineItems: nil,
            reviewRequests: nil,
            reviews: ReviewsConnection(nodes: [
                makeReviewNode(login: "bob", state: "APPROVED"),
                makeReviewNode(login: "alice", state: "COMMENTED"),
                makeReviewNode(login: "bob", state: "CHANGES_REQUESTED"),
            ]),
            commits: nil
        )
        let reviewers = node.toReviewers()
        #expect(reviewers.count == 2)
        #expect(reviewers[0].displayName == "bob")
        #expect(reviewers[0].state == .changesRequested)
        #expect(reviewers[1].displayName == "alice")
    }

    // MARK: - Requested Reviewers

    @Test("pending reviewer added from requests")
    func pendingReviewerFromRequests() {
        let node = TimelinePullRequestNode(
            timelineItems: nil,
            reviewRequests: ReviewRequestsConnection(nodes: [makeRequestNode(login: "alice")]),
            reviews: nil,
            commits: nil
        )
        let reviewers = node.toReviewers()
        #expect(reviewers.count == 1)
        #expect(reviewers[0].state == .pending)
        #expect(reviewers[0].displayName == "alice")
    }

    @Test("team reviewer has isTeam set and uses name")
    func teamReviewer() {
        let node = TimelinePullRequestNode(
            timelineItems: nil,
            reviewRequests: ReviewRequestsConnection(nodes: [makeRequestNode(typename: "Team", name: "backend-team")]),
            reviews: nil,
            commits: nil
        )
        let reviewers = node.toReviewers()
        #expect(reviewers.count == 1)
        #expect(reviewers[0].isTeam)
        #expect(reviewers[0].displayName == "backend-team")
        #expect(reviewers[0].state == .pending)
    }

    @Test("requested reviewer who already reviewed is not duplicated")
    func requestedReviewerNotDuplicated() {
        let node = TimelinePullRequestNode(
            timelineItems: nil,
            reviewRequests: ReviewRequestsConnection(nodes: [makeRequestNode(login: "alice")]),
            reviews: ReviewsConnection(nodes: [makeReviewNode(login: "alice", state: "APPROVED")]),
            commits: nil
        )
        let reviewers = node.toReviewers()
        #expect(reviewers.count == 1)
        #expect(reviewers[0].state == .approved)
    }

    @Test("unknown review state is skipped")
    func unknownStateIsSkipped() {
        let node = TimelinePullRequestNode(
            timelineItems: nil,
            reviewRequests: nil,
            reviews: ReviewsConnection(nodes: [makeReviewNode(login: "alice", state: "UNKNOWN_STATE")]),
            commits: nil
        )
        let reviewers = node.toReviewers()
        #expect(reviewers.isEmpty)
    }

    @Test("review with nil author is skipped")
    func nilAuthorSkipped() {
        let node = TimelinePullRequestNode(
            timelineItems: nil,
            reviewRequests: nil,
            reviews: ReviewsConnection(nodes: [ReviewNode(author: nil, state: "APPROVED")]),
            commits: nil
        )
        let reviewers = node.toReviewers()
        #expect(reviewers.isEmpty)
    }
}
