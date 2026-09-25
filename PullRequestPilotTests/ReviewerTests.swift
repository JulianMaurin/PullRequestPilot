import Testing
import Foundation
@testable import PullRequestPilot

@Suite("Reviewer Model")
struct ReviewerTests {

    // MARK: - Identity

    @Test("Identical reviewers are equal")
    func identicalReviewersAreEqual() {
        let reviewer1 = Reviewer(id: "u1", displayName: "Alice", avatarURL: nil, isTeam: false, state: .pending)
        let reviewer2 = Reviewer(id: "u1", displayName: "Alice", avatarURL: nil, isTeam: false, state: .pending)
        #expect(reviewer1 == reviewer2)
    }

    @Test("Reviewers with different ids are not equal")
    func differentIdsAreNotEqual() {
        let reviewer1 = Reviewer(id: "u1", displayName: "Alice", avatarURL: nil, isTeam: false, state: .pending)
        let reviewer2 = Reviewer(id: "u2", displayName: "Alice", avatarURL: nil, isTeam: false, state: .pending)
        #expect(reviewer1 != reviewer2)
    }

    @Test("Reviewers with same id but different state are not equal")
    func differentStatesAreNotEqual() {
        let reviewer1 = Reviewer(id: "u1", displayName: "Alice", avatarURL: nil, isTeam: false, state: .pending)
        let reviewer2 = Reviewer(id: "u1", displayName: "Alice", avatarURL: nil, isTeam: false, state: .approved)
        #expect(reviewer1 != reviewer2)
    }

    // MARK: - Identifiable

    @Test("Reviewer id is used for identity")
    func identifiableUsesId() {
        let reviewer = Reviewer(id: "test-id", displayName: "Alice", avatarURL: nil, isTeam: false, state: .approved)
        #expect(reviewer.id == "test-id")
    }

    // MARK: - Hashability

    @Test("Equal reviewers produce the same hash")
    func hashConsistentWithEquality() {
        let reviewer1 = Reviewer(id: "u1", displayName: "Alice", avatarURL: nil, isTeam: false, state: .pending)
        let reviewer2 = Reviewer(id: "u1", displayName: "Alice", avatarURL: nil, isTeam: false, state: .pending)
        #expect(reviewer1.hashValue == reviewer2.hashValue)
    }

    @Test("Reviewers can be stored in a Set and deduplicated")
    func setMembership() {
        let reviewer1 = Reviewer(id: "u1", displayName: "Alice", avatarURL: nil, isTeam: false, state: .pending)
        let reviewer2 = Reviewer(id: "u1", displayName: "Alice", avatarURL: nil, isTeam: false, state: .pending)
        let reviewer3 = Reviewer(id: "u2", displayName: "Carol", avatarURL: nil, isTeam: false, state: .commented)
        let set: Set<Reviewer> = [reviewer1, reviewer2, reviewer3]
        #expect(set.count == 2)
    }
}

@Suite("ReviewerState")
struct ReviewerStateTests {

    // MARK: - Priority

    @Test("Priority values are correct for each state")
    func priorityValues() {
        #expect(ReviewerState.pending.priority == 0)
        #expect(ReviewerState.dismissed.priority == 1)
        #expect(ReviewerState.commented.priority == 2)
        #expect(ReviewerState.changesRequested.priority == 3)
        #expect(ReviewerState.approved.priority == 4)
    }

    @Test("Priority ordering: approved > changesRequested > commented > dismissed > pending")
    func priorityOrdering() {
        #expect(ReviewerState.approved.priority > ReviewerState.changesRequested.priority)
        #expect(ReviewerState.changesRequested.priority > ReviewerState.commented.priority)
        #expect(ReviewerState.commented.priority > ReviewerState.dismissed.priority)
        #expect(ReviewerState.dismissed.priority > ReviewerState.pending.priority)
    }

    // MARK: - Icon Name

    @Test("iconName returns correct SF Symbol for each state",
          arguments: [
              (ReviewerState.pending, "clock"),
              (ReviewerState.approved, "checkmark"),
              (ReviewerState.changesRequested, "xmark"),
              (ReviewerState.commented, "text.bubble"),
              (ReviewerState.dismissed, "arrow.uturn.left"),
          ])
    func iconName(state: ReviewerState, expected: String) {
        #expect(state.iconName == expected)
    }

    // MARK: - Icon Color

    @Test("iconTint returns the right tint for each state",
          arguments: [
              (ReviewerState.pending, StatusTint.yellow),
              (ReviewerState.approved, StatusTint.green),
              (ReviewerState.changesRequested, StatusTint.red),
              (ReviewerState.commented, StatusTint.blue),
              (ReviewerState.dismissed, StatusTint.gray),
          ])
    func iconTint(state: ReviewerState, expected: StatusTint) {
        #expect(state.iconTint == expected)
    }

    // MARK: - Label

    @Test("label returns correct display text for each state",
          arguments: [
              (ReviewerState.pending, "Awaiting review"),
              (ReviewerState.approved, "Approved"),
              (ReviewerState.changesRequested, "Changes requested"),
              (ReviewerState.commented, "Commented"),
              (ReviewerState.dismissed, "Dismissed"),
          ])
    func label(state: ReviewerState, expected: String) {
        #expect(state.label == expected)
    }
}
