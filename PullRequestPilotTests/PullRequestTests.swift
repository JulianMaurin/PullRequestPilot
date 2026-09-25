import Testing
import Foundation
@testable import PullRequestPilot

@Suite("PullRequest Model")
struct PullRequestTests {

    // MARK: - Repository

    @Test("Repository parses owner from nameWithOwner")
    func repositoryOwner() {
        let repo = Repository(nameWithOwner: "octocat/hello-world")
        #expect(repo.owner == "octocat")
        #expect(repo.name == "hello-world")
    }

    @Test("Repository handles single-segment name")
    func repositorySingleSegment() {
        let repo = Repository(nameWithOwner: "solo")
        #expect(repo.owner == "solo")
        #expect(repo.name == "solo")
    }

    @Test("Repository handles empty string")
    func repositoryEmpty() {
        let repo = Repository(nameWithOwner: "")
        #expect(repo.owner == "")
        #expect(repo.name == "")
    }

    // MARK: - linesChanged

    @Test("linesChanged sums additions and deletions")
    func linesChanged() throws {
        let pr = try TestPullRequestFactory.make(additions: 42, deletions: 13)
        #expect(pr.linesChanged == 55)
    }

    @Test("linesChanged is zero when no changes")
    func linesChangedZero() throws {
        let pr = try TestPullRequestFactory.make(additions: 0, deletions: 0)
        #expect(pr.linesChanged == 0)
    }

    // MARK: - age

    @Test("age returns a relative time string")
    func ageReturnsRelativeString() throws {
        let pr = try TestPullRequestFactory.make(createdAt: Date().addingTimeInterval(-7200))
        let age = pr.age
        #expect(!age.isEmpty)
    }

    // MARK: - PullRequestState

    @Test("PullRequestState raw values match GitHub API")
    func pullRequestStateRawValues() {
        #expect(PullRequestState.open.rawValue == "OPEN")
        #expect(PullRequestState.closed.rawValue == "CLOSED")
        #expect(PullRequestState.merged.rawValue == "MERGED")
    }

    // MARK: - CheckStatus

    @Test("CheckStatus raw values match GitHub API")
    func checkStatusRawValues() {
        #expect(CheckStatus.pending.rawValue == "PENDING")
        #expect(CheckStatus.success.rawValue == "SUCCESS")
        #expect(CheckStatus.failure.rawValue == "FAILURE")
        #expect(CheckStatus.error.rawValue == "ERROR")
        #expect(CheckStatus.expected.rawValue == "EXPECTED")
    }

    // MARK: - ReviewDecision

    @Test("ReviewDecision raw values match GitHub API")
    func reviewDecisionRawValues() {
        #expect(ReviewDecision.approved.rawValue == "APPROVED")
        #expect(ReviewDecision.changesRequested.rawValue == "CHANGES_REQUESTED")
        #expect(ReviewDecision.reviewRequired.rawValue == "REVIEW_REQUIRED")
    }

    // MARK: - ReviewState

    @Test("ReviewState has all expected cases")
    func reviewStateRawValues() {
        #expect(ReviewState.approved.rawValue == "APPROVED")
        #expect(ReviewState.changesRequested.rawValue == "CHANGES_REQUESTED")
        #expect(ReviewState.commented.rawValue == "COMMENTED")
        #expect(ReviewState.dismissed.rawValue == "DISMISSED")
        #expect(ReviewState.pending.rawValue == "PENDING")
    }

    // MARK: - ActivityKind

    @Test("ActivityKind.iconName returns correct SF Symbols")
    func activityKindIconNames() {
        #expect(ActivityKind.comment.iconName == "text.bubble")
        #expect(ActivityKind.review(.approved).iconName == "checkmark.circle")
        #expect(ActivityKind.review(.changesRequested).iconName == "xmark.circle")
        #expect(ActivityKind.review(.reviewRequired).iconName == "eye")
        #expect(ActivityKind.review(nil).iconName == "eye")
        #expect(ActivityKind.merged.iconName == "arrow.triangle.merge")
        #expect(ActivityKind.closed.iconName == "xmark.circle")
        #expect(ActivityKind.forcePushed.iconName == "arrow.up.to.line")
        #expect(ActivityKind.committed.iconName == "smallcircle.filled.circle")
    }

    // MARK: - LastActivity

    @Test("LastActivity.label for all activity kinds with actor")
    func lastActivityLabelWithActor() {
        let actor = Author(login: "alice", avatarURL: nil)
        let ts = Date()

        #expect(LastActivity(kind: .comment, actor: actor, timestamp: ts).label == "comment by alice")
        #expect(LastActivity(kind: .review(.approved), actor: actor, timestamp: ts).label == "approved by alice")
        #expect(LastActivity(kind: .review(.changesRequested), actor: actor, timestamp: ts).label == "changes requested by alice")
        #expect(LastActivity(kind: .review(.reviewRequired), actor: actor, timestamp: ts).label == "reviewed by alice")
        #expect(LastActivity(kind: .review(nil), actor: actor, timestamp: ts).label == "reviewed by alice")
        #expect(LastActivity(kind: .merged, actor: actor, timestamp: ts).label == "merged by alice")
        #expect(LastActivity(kind: .closed, actor: actor, timestamp: ts).label == "closed by alice")
        #expect(LastActivity(kind: .forcePushed, actor: actor, timestamp: ts).label == "force pushed by alice")
        #expect(LastActivity(kind: .committed, actor: actor, timestamp: ts).label == "commit by alice")
    }

    @Test("LastActivity.label falls back to 'someone' when actor is nil")
    func lastActivityLabelWithoutActor() {
        let activity = LastActivity(kind: .comment, actor: nil, timestamp: Date())
        #expect(activity.label == "comment by someone")
    }

    @Test("LastActivity.timestampText shows 'today' for today's date")
    func timestampTextToday() {
        let activity = LastActivity(kind: .comment, actor: nil, timestamp: Date())
        #expect(activity.timestampText.hasPrefix("today at"))
    }

    @Test("LastActivity.timestampText shows 'yesterday' for yesterday's date")
    func timestampTextYesterday() throws {
        let yesterday = try #require(Calendar.current.date(byAdding: .day, value: -1, to: Date()))
        let activity = LastActivity(kind: .comment, actor: nil, timestamp: yesterday)
        #expect(activity.timestampText.hasPrefix("yesterday at"))
    }

    @Test("LastActivity.timestampText shows date for older dates")
    func timestampTextOlderDate() throws {
        let oldDate = try #require(Calendar.current.date(byAdding: .day, value: -10, to: Date()))
        let activity = LastActivity(kind: .comment, actor: nil, timestamp: oldDate)
        #expect(!activity.timestampText.hasPrefix("today"))
        #expect(!activity.timestampText.hasPrefix("yesterday"))
        #expect(activity.timestampText.contains("at"))
    }

    // MARK: - age(relativeTo:)

    @Test("age(relativeTo:) computes relative time from the given date")
    func ageRelativeTo() throws {
        let createdAt = Date(timeIntervalSince1970: 1_000_000)
        let pr = try TestPullRequestFactory.make(createdAt: createdAt)
        let oneHourLater = createdAt.addingTimeInterval(3600)
        let age = pr.age(relativeTo: oneHourLater)
        #expect(!age.isEmpty)
        // The exact format depends on locale, but it should differ from "0 seconds"
        #expect(age != pr.age(relativeTo: createdAt))
    }

    @Test("age(relativeTo:) renders future createdAt as 'just now'")
    func ageRelativeToFutureCreatedAt() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let pr = try TestPullRequestFactory.make(createdAt: now.addingTimeInterval(90))
        #expect(pr.age(relativeTo: now) == "just now")
    }

    @Test("age(relativeTo:) changes as the reference date advances")
    func ageRelativeToAdvances() throws {
        let createdAt = Date(timeIntervalSince1970: 1_000_000)
        let pr = try TestPullRequestFactory.make(createdAt: createdAt)
        let age1 = pr.age(relativeTo: createdAt.addingTimeInterval(60))
        let age2 = pr.age(relativeTo: createdAt.addingTimeInterval(86400))
        #expect(age1 != age2)
    }

    // MARK: - timestampText(relativeTo:)

    @Test("timestampText(relativeTo:) shows 'today' when same day")
    func timestampTextRelativeToToday() {
        let activity = LastActivity(kind: .comment, actor: nil, timestamp: Date())
        #expect(activity.timestampText(relativeTo: Date()).hasPrefix("today at"))
    }

    // MARK: - Hashable / Identifiable

    @Test("PullRequest identity is based on id")
    func pullRequestIdentity() throws {
        let pr1 = try TestPullRequestFactory.make(id: "PR_1", title: "First")
        let pr2 = try TestPullRequestFactory.make(id: "PR_1", title: "Second")
        let pr3 = try TestPullRequestFactory.make(id: "PR_2", title: "First")
        #expect(pr1.id == pr2.id)
        #expect(pr1.id != pr3.id)
    }
}
