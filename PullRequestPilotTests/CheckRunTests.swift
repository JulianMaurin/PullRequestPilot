import Testing
import Foundation
@testable import PullRequestPilot

@Suite("CheckRun Model")
struct CheckRunTests {

    // MARK: - DisplayStatus

    @Test("displayStatus shows conclusion label when present")
    func displayStatusWithConclusion() {
        let check = CheckRun(id: "1", name: "CI", status: .completed, conclusion: .success, detailsURL: nil)
        #expect(check.displayStatus == "Success")
    }

    @Test("displayStatus shows status label when no conclusion")
    func displayStatusWithoutConclusion() {
        let check = CheckRun(id: "1", name: "CI", status: .inProgress, conclusion: nil, detailsURL: nil)
        #expect(check.displayStatus == "In progress")
    }

    // MARK: - IconName

    @Test("iconName uses conclusion when present")
    func iconNameWithConclusion() {
        let check = CheckRun(id: "1", name: "CI", status: .completed, conclusion: .failure, detailsURL: nil)
        #expect(check.iconName == "xmark")
    }

    @Test("iconName uses status when no conclusion")
    func iconNameWithoutConclusion() {
        let check = CheckRun(id: "1", name: "CI", status: .queued, conclusion: nil, detailsURL: nil)
        #expect(check.iconName == "clock")
    }

    // MARK: - IconColor

    @Test("iconColor uses conclusion when present")
    func iconColorWithConclusion() {
        let check = CheckRun(id: "1", name: "CI", status: .completed, conclusion: .success, detailsURL: nil)
        #expect(check.iconColor == "green")
    }

    @Test("iconColor uses status when no conclusion")
    func iconColorWithoutConclusion() {
        let check = CheckRun(id: "1", name: "CI", status: .inProgress, conclusion: nil, detailsURL: nil)
        #expect(check.iconColor == "yellow")
    }

    // MARK: - CheckRunStatus

    @Test("CheckRunStatus raw values match GitHub API")
    func statusRawValues() {
        #expect(CheckRunStatus.queued.rawValue == "QUEUED")
        #expect(CheckRunStatus.inProgress.rawValue == "IN_PROGRESS")
        #expect(CheckRunStatus.completed.rawValue == "COMPLETED")
        #expect(CheckRunStatus.waiting.rawValue == "WAITING")
        #expect(CheckRunStatus.pending.rawValue == "PENDING")
        #expect(CheckRunStatus.requested.rawValue == "REQUESTED")
    }

    // MARK: - CheckRunConclusion

    @Test("CheckRunConclusion raw values match GitHub API")
    func conclusionRawValues() {
        #expect(CheckRunConclusion.success.rawValue == "SUCCESS")
        #expect(CheckRunConclusion.failure.rawValue == "FAILURE")
        #expect(CheckRunConclusion.neutral.rawValue == "NEUTRAL")
        #expect(CheckRunConclusion.cancelled.rawValue == "CANCELLED")
        #expect(CheckRunConclusion.timedOut.rawValue == "TIMED_OUT")
        #expect(CheckRunConclusion.actionRequired.rawValue == "ACTION_REQUIRED")
        #expect(CheckRunConclusion.skipped.rawValue == "SKIPPED")
        #expect(CheckRunConclusion.stale.rawValue == "STALE")
        #expect(CheckRunConclusion.startupFailure.rawValue == "STARTUP_FAILURE")
    }

    // MARK: - Conclusion Icons & Colors

    @Test("conclusion iconName covers all cases")
    func conclusionIconNames() {
        #expect(CheckRunConclusion.success.iconName == "checkmark")
        #expect(CheckRunConclusion.failure.iconName == "xmark")
        #expect(CheckRunConclusion.startupFailure.iconName == "xmark")
        #expect(CheckRunConclusion.cancelled.iconName == "xmark.circle")
        #expect(CheckRunConclusion.timedOut.iconName == "xmark.circle")
        #expect(CheckRunConclusion.neutral.iconName == "minus")
        #expect(CheckRunConclusion.stale.iconName == "minus")
        #expect(CheckRunConclusion.actionRequired.iconName == "exclamationmark.triangle")
        #expect(CheckRunConclusion.skipped.iconName == "arrow.right")
    }

    @Test("conclusion iconColor covers all cases")
    func conclusionIconColors() {
        #expect(CheckRunConclusion.success.iconColor == "green")
        #expect(CheckRunConclusion.failure.iconColor == "red")
        #expect(CheckRunConclusion.timedOut.iconColor == "red")
        #expect(CheckRunConclusion.cancelled.iconColor == "gray")
        #expect(CheckRunConclusion.skipped.iconColor == "gray")
        #expect(CheckRunConclusion.actionRequired.iconColor == "yellow")
    }
}

@Suite("CheckRun DTO Mapping")
struct CheckRunDTOMappingTests {

    private func makeCheckRunNode(name: String, status: String, conclusion: String? = nil, detailsUrl: String? = nil) -> CheckRunContextNode {
        CheckRunContextNode(
            __typename: "CheckRun",
            name: name,
            status: status,
            conclusion: conclusion,
            detailsUrl: detailsUrl,
            context: nil,
            state: nil,
            targetUrl: nil
        )
    }

    private func makeStatusContextNode(context: String, state: String, targetUrl: String? = nil) -> CheckRunContextNode {
        CheckRunContextNode(
            __typename: "StatusContext",
            name: nil,
            status: nil,
            conclusion: nil,
            detailsUrl: nil,
            context: context,
            state: state,
            targetUrl: targetUrl
        )
    }

    private func makeConnection(_ nodes: [CheckRunContextNode]) -> CheckRunCommitsConnection {
        CheckRunCommitsConnection(nodes: [
            .init(commit: .init(statusCheckRollup: .init(contexts: .init(nodes: nodes)))),
        ])
    }

    @Test("maps CheckRun with success conclusion")
    func mapsCheckRunSuccess() {
        let connection = makeConnection([
            makeCheckRunNode(name: "CI", status: "COMPLETED", conclusion: "SUCCESS"),
        ])
        let results = connection.toDomain()
        #expect(results.count == 1)
        #expect(results[0].name == "CI")
        #expect(results[0].status == .completed)
        #expect(results[0].conclusion == .success)
    }

    @Test("maps CheckRun without conclusion")
    func mapsCheckRunInProgress() {
        let connection = makeConnection([
            makeCheckRunNode(name: "CI", status: "IN_PROGRESS"),
        ])
        let results = connection.toDomain()
        #expect(results[0].status == .inProgress)
        #expect(results[0].conclusion == nil)
    }

    @Test("maps StatusContext with SUCCESS state")
    func mapsStatusContextSuccess() {
        let connection = makeConnection([
            makeStatusContextNode(context: "ci/build", state: "SUCCESS"),
        ])
        let results = connection.toDomain()
        #expect(results.count == 1)
        #expect(results[0].name == "ci/build")
        #expect(results[0].conclusion == .success)
    }

    @Test("maps StatusContext with PENDING state")
    func mapsStatusContextPending() {
        let connection = makeConnection([
            makeStatusContextNode(context: "ci/build", state: "PENDING"),
        ])
        let results = connection.toDomain()
        #expect(results[0].status == .pending)
        #expect(results[0].conclusion == nil)
    }

    @Test("deduplicates by name, preferring CheckRun over StatusContext")
    func deduplicatesPreferringCheckRun() {
        let connection = makeConnection([
            makeStatusContextNode(context: "CI", state: "SUCCESS"),
            makeCheckRunNode(name: "CI", status: "COMPLETED", conclusion: "FAILURE", detailsUrl: "https://example.com"),
        ])
        let results = connection.toDomain()
        #expect(results.count == 1)
        #expect(results[0].conclusion == .failure)
        #expect(results[0].detailsURL != nil)
    }

    @Test("preserves detailsUrl from CheckRun")
    func preservesDetailsUrl() {
        let connection = makeConnection([
            makeCheckRunNode(name: "CI", status: "COMPLETED", conclusion: "SUCCESS", detailsUrl: "https://example.com/run/1"),
        ])
        let results = connection.toDomain()
        #expect(results[0].detailsURL?.absoluteString == "https://example.com/run/1")
    }

    @Test("returns empty for no rollup")
    func emptyForNoRollup() {
        let connection = CheckRunCommitsConnection(nodes: [
            .init(commit: .init(statusCheckRollup: nil)),
        ])
        let results = connection.toDomain()
        #expect(results.isEmpty)
    }

    @Test("skips unknown typename")
    func skipsUnknownTypename() {
        let node = CheckRunContextNode(
            __typename: "Unknown",
            name: nil, status: nil, conclusion: nil, detailsUrl: nil,
            context: nil, state: nil, targetUrl: nil
        )
        let connection = makeConnection([node])
        let results = connection.toDomain()
        #expect(results.isEmpty)
    }
}
