import Testing
import Foundation
@testable import PullRequestPilot

@Suite("TimelineEvent Model")
struct TimelineEventTests {

    private func makeEvent(
        id: String = "1",
        kind: TimelineEventKind = .comment,
        actor: Author? = Author(login: "alice", avatarURL: nil),
        timestamp: Date = Date(),
        body: String? = nil
    ) -> TimelineEvent {
        TimelineEvent(id: id, kind: kind, actor: actor, timestamp: timestamp, body: body)
    }

    // MARK: - Labels

    @Test("label for comment")
    func labelComment() {
        let event = makeEvent(kind: .comment)
        #expect(event.label == "alice commented")
    }

    @Test("label for approved review")
    func labelApproved() {
        let event = makeEvent(kind: .review(.approved))
        #expect(event.label == "alice approved")
    }

    @Test("label for changes requested review")
    func labelChangesRequested() {
        let event = makeEvent(kind: .review(.changesRequested))
        #expect(event.label == "alice requested changes")
    }

    @Test("label for commented review")
    func labelCommentedReview() {
        let event = makeEvent(kind: .review(.commented))
        #expect(event.label == "alice reviewed")
    }

    @Test("label for merged")
    func labelMerged() {
        let event = makeEvent(kind: .merged)
        #expect(event.label == "alice merged")
    }

    @Test("label for closed")
    func labelClosed() {
        let event = makeEvent(kind: .closed)
        #expect(event.label == "alice closed")
    }

    @Test("label for reopened")
    func labelReopened() {
        let event = makeEvent(kind: .reopened)
        #expect(event.label == "alice reopened")
    }

    @Test("label for force pushed")
    func labelForcePushed() {
        let event = makeEvent(kind: .forcePushed)
        #expect(event.label == "alice force pushed")
    }

    @Test("label for commit")
    func labelCommit() {
        let event = makeEvent(kind: .commit(message: nil))
        #expect(event.label == "alice pushed a commit")
    }

    @Test("label for ready for review")
    func labelReadyForReview() {
        let event = makeEvent(kind: .readyForReview)
        #expect(event.label == "alice marked ready for review")
    }

    @Test("label for converted to draft")
    func labelConvertedToDraft() {
        let event = makeEvent(kind: .convertedToDraft)
        #expect(event.label == "alice converted to draft")
    }

    @Test("label for assigned")
    func labelAssigned() {
        let event = makeEvent(kind: .assigned(assignee: "bob"))
        #expect(event.label == "alice assigned bob")
    }

    @Test("label for review requested")
    func labelReviewRequested() {
        let event = makeEvent(kind: .reviewRequested(reviewer: "bob"))
        #expect(event.label == "alice requested review from bob")
    }

    @Test("label falls back to 'someone' when actor is nil")
    func labelNoActor() {
        let event = makeEvent(actor: nil)
        #expect(event.label == "someone commented")
    }

    // MARK: - Icon Names

    @Test("iconName returns correct SF Symbols for all kinds")
    func iconNames() {
        #expect(makeEvent(kind: .comment).iconName == "text.bubble")
        #expect(makeEvent(kind: .review(.approved)).iconName == "checkmark.circle")
        #expect(makeEvent(kind: .review(.changesRequested)).iconName == "xmark.circle")
        #expect(makeEvent(kind: .review(nil)).iconName == "eye")
        #expect(makeEvent(kind: .merged).iconName == "arrow.triangle.merge")
        #expect(makeEvent(kind: .closed).iconName == "xmark.circle")
        #expect(makeEvent(kind: .reopened).iconName == "arrow.uturn.left.circle")
        #expect(makeEvent(kind: .forcePushed).iconName == "arrow.up.to.line")
        #expect(makeEvent(kind: .commit(message: nil)).iconName == "smallcircle.filled.circle")
        #expect(makeEvent(kind: .readyForReview).iconName == "eye.circle")
        #expect(makeEvent(kind: .convertedToDraft).iconName == "doc.circle")
        #expect(makeEvent(kind: .assigned(assignee: "x")).iconName == "person.badge.plus")
        #expect(makeEvent(kind: .reviewRequested(reviewer: "x")).iconName == "person.wave.2")
    }

    // MARK: - Timestamp

    @Test("timestampText shows 'today' for today's date")
    func timestampToday() {
        let event = makeEvent(timestamp: Date())
        #expect(event.timestampText.hasPrefix("today at"))
    }

    @Test("timestampText shows 'yesterday' for yesterday's date")
    func timestampYesterday() {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let event = makeEvent(timestamp: yesterday)
        #expect(event.timestampText.hasPrefix("yesterday at"))
    }

    @Test("timestampText shows date for older dates")
    func timestampOlderDate() {
        let oldDate = Calendar.current.date(byAdding: .day, value: -10, to: Date())!
        let event = makeEvent(timestamp: oldDate)
        #expect(!event.timestampText.hasPrefix("today"))
        #expect(!event.timestampText.hasPrefix("yesterday"))
        #expect(event.timestampText.contains("at"))
    }

    // MARK: - Identity

    @Test("TimelineEvent uses id for identity")
    func identity() {
        let e1 = makeEvent(id: "a")
        let e2 = makeEvent(id: "a")
        let e3 = makeEvent(id: "b")
        #expect(e1.id == e2.id)
        #expect(e1.id != e3.id)
    }
}
