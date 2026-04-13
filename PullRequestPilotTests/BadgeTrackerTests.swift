import Testing
import Foundation
@testable import PullRequestPilot

@MainActor
@Suite("BadgeTracker")
struct BadgeTrackerTests {
    private func makeTracker(suiteName: String) -> BadgeTracker {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return BadgeTracker(defaults: defaults)
    }

    @Test("isEnabled returns false by default")
    func isEnabledDefault() {
        let tracker = makeTracker(suiteName: "BadgeDefault")
        #expect(!tracker.isEnabled(for: UUID()))
    }

    @Test("setEnabled enables and disables badge tracking")
    func setEnabledToggle() {
        let tracker = makeTracker(suiteName: "BadgeToggle")
        let viewID = UUID()

        tracker.setEnabled(for: viewID, enabled: true, currentPRs: [])
        #expect(tracker.isEnabled(for: viewID))

        tracker.setEnabled(for: viewID, enabled: false, currentPRs: [])
        #expect(!tracker.isEnabled(for: viewID))
    }

    @Test("detectNewPRs returns empty on first load")
    func detectNewPRsFirstLoad() {
        let tracker = makeTracker(suiteName: "BadgeFirstLoad")
        let viewID = UUID()
        let pr = TestPullRequestFactory.make(id: "PR_1")

        let added = tracker.detectNewPRs(viewID: viewID, currentPRs: [pr])
        #expect(added.isEmpty)
    }

    @Test("detectNewPRs detects new PRs on subsequent loads")
    func detectNewPRsSubsequent() {
        let tracker = makeTracker(suiteName: "BadgeSubsequent")
        let viewID = UUID()
        let pr1 = TestPullRequestFactory.make(id: "PR_1")
        let pr2 = TestPullRequestFactory.make(id: "PR_2", number: 2)

        _ = tracker.detectNewPRs(viewID: viewID, currentPRs: [pr1])
        let added = tracker.detectNewPRs(viewID: viewID, currentPRs: [pr1, pr2])

        #expect(added == Set(["PR_2"]))
    }

    @Test("trackUnseen adds IDs and updates count")
    func trackUnseen() {
        let tracker = makeTracker(suiteName: "BadgeTrackUnseen")
        #expect(tracker.count == 0)

        tracker.trackUnseen(Set(["PR_1", "PR_2"]))
        #expect(tracker.count == 2)
    }

    @Test("markAsSeen clears unseen count")
    func markAsSeen() {
        let tracker = makeTracker(suiteName: "BadgeMarkSeen")
        tracker.trackUnseen(Set(["PR_1"]))
        #expect(tracker.count == 1)

        tracker.markAsSeen()
        #expect(tracker.count == 0)
    }

    @Test("pruneUnseen removes IDs no longer in any view")
    func pruneUnseen() {
        let tracker = makeTracker(suiteName: "BadgePrune")
        let viewID = UUID()
        tracker.setEnabled(for: viewID, enabled: true, currentPRs: [])
        tracker.trackUnseen(Set(["PR_1", "PR_2"]))

        let pr1 = TestPullRequestFactory.make(id: "PR_1")
        let viewStates: [UUID: ViewState] = [viewID: ViewState(pullRequests: [pr1])]
        tracker.pruneUnseen(viewStates: viewStates)

        #expect(tracker.count == 1)
        #expect(tracker.unseenPRIDs.contains("PR_1"))
        #expect(!tracker.unseenPRIDs.contains("PR_2"))
    }

    @Test("removeView cleans up tracking state")
    func removeView() {
        let tracker = makeTracker(suiteName: "BadgeRemoveView")
        let viewID = UUID()
        tracker.setEnabled(for: viewID, enabled: true, currentPRs: [])
        #expect(tracker.isEnabled(for: viewID))

        tracker.removeView(id: viewID)
        #expect(!tracker.isEnabled(for: viewID))
    }

    @Test("reset clears all state")
    func resetClearsAll() {
        let tracker = makeTracker(suiteName: "BadgeReset")
        let viewID = UUID()
        tracker.setEnabled(for: viewID, enabled: true, currentPRs: [])
        tracker.trackUnseen(Set(["PR_1"]))

        tracker.reset()

        #expect(!tracker.isEnabled(for: viewID))
        #expect(tracker.count == 0)
        #expect(tracker.unseenPRIDs.isEmpty)
    }

    @Test("onCountChanged callback fires when count changes")
    func onCountChangedFires() {
        let tracker = makeTracker(suiteName: "BadgeCallback")
        var callbackValues: [Int] = []
        tracker.onCountChanged = { callbackValues.append($0) }

        tracker.trackUnseen(Set(["PR_1"]))
        tracker.markAsSeen()

        #expect(callbackValues == [1, 0])
    }

    @Test("enabledViewIDs persists across instances")
    func persistence() {
        let suiteName = "BadgePersist"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let viewID = UUID()

        let tracker1 = BadgeTracker(defaults: defaults)
        tracker1.setEnabled(for: viewID, enabled: true, currentPRs: [])

        let tracker2 = BadgeTracker(defaults: defaults)
        #expect(tracker2.isEnabled(for: viewID))
    }
}
