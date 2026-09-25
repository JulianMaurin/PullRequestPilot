import Testing
import Foundation
@testable import PullRequestPilot

@Suite("CheckRun Model")
struct CheckRunTests {

    // MARK: - DisplayStatus

    @Test("displayStatus shows conclusion label when present")
    func displayStatusWithConclusion() {
        let check = CheckRun(id: "1", name: "CI", status: .completed, conclusion: .success, detailsURL: nil, isRequired: false, workflowRunID: nil, startedAt: nil)
        #expect(check.displayStatus == "Success")
    }

    @Test("displayStatus shows status label when no conclusion")
    func displayStatusWithoutConclusion() {
        let check = CheckRun(id: "1", name: "CI", status: .inProgress, conclusion: nil, detailsURL: nil, isRequired: false, workflowRunID: nil, startedAt: nil)
        #expect(check.displayStatus == "In progress")
    }

    // MARK: - IconName

    @Test("iconName uses conclusion when present")
    func iconNameWithConclusion() {
        let check = CheckRun(id: "1", name: "CI", status: .completed, conclusion: .failure, detailsURL: nil, isRequired: false, workflowRunID: nil, startedAt: nil)
        #expect(check.iconName == "xmark")
    }

    @Test("iconName uses status when no conclusion")
    func iconNameWithoutConclusion() {
        let check = CheckRun(id: "1", name: "CI", status: .queued, conclusion: nil, detailsURL: nil, isRequired: false, workflowRunID: nil, startedAt: nil)
        #expect(check.iconName == "clock")
    }

    // MARK: - IconColor

    @Test("iconTint uses conclusion when present")
    func iconTintWithConclusion() {
        let check = CheckRun(id: "1", name: "CI", status: .completed, conclusion: .success, detailsURL: nil, isRequired: false, workflowRunID: nil, startedAt: nil)
        #expect(check.iconTint == .green)
    }

    @Test("iconTint uses status when no conclusion")
    func iconTintWithoutConclusion() {
        let check = CheckRun(id: "1", name: "CI", status: .inProgress, conclusion: nil, detailsURL: nil, isRequired: false, workflowRunID: nil, startedAt: nil)
        #expect(check.iconTint == .yellow)
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

    @Test("conclusion iconTint covers all cases")
    func conclusionIconColors() {
        #expect(CheckRunConclusion.success.iconTint == .green)
        #expect(CheckRunConclusion.failure.iconTint == .red)
        #expect(CheckRunConclusion.timedOut.iconTint == .red)
        #expect(CheckRunConclusion.cancelled.iconTint == .gray)
        #expect(CheckRunConclusion.skipped.iconTint == .gray)
        #expect(CheckRunConclusion.actionRequired.iconTint == .yellow)
    }
}

@Suite("CheckRun DTO Mapping")
struct CheckRunDTOMappingTests {

    private func makeCheckRunNode(
        name: String,
        status: String,
        conclusion: String? = nil,
        detailsUrl: String? = nil,
        isRequired: Bool? = nil,
        workflowRunID: Int? = nil,
        startedAt: String? = nil
    ) -> CheckRunContextNode {
        CheckRunContextNode(
            typename: "CheckRun",
            name: name,
            status: status,
            conclusion: conclusion,
            detailsUrl: detailsUrl,
            isRequired: isRequired,
            startedAt: startedAt,
            checkSuite: workflowRunID.map { .init(workflowRun: .init(databaseId: $0)) },
            context: nil,
            state: nil,
            targetUrl: nil
        )
    }

    private func makeStatusContextNode(context: String, state: String, targetUrl: String? = nil) -> CheckRunContextNode {
        CheckRunContextNode(
            typename: "StatusContext",
            name: nil,
            status: nil,
            conclusion: nil,
            detailsUrl: nil,
            isRequired: nil,
            startedAt: nil,
            checkSuite: nil,
            context: context,
            state: state,
            targetUrl: targetUrl
        )
    }

    private func makeConnection(_ nodes: [CheckRunContextNode]) -> CheckRunCommitsConnection {
        CheckRunCommitsConnection(nodes: [
            .init(commit: .init(statusCheckRollup: .init(contexts: .init(nodes: nodes, pageInfo: nil)))),
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
        let results = connection.toDomain().deduplicatedLatest()
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
            typename: "Unknown",
            name: nil, status: nil, conclusion: nil, detailsUrl: nil, isRequired: nil,
            startedAt: nil, checkSuite: nil,
            context: nil, state: nil, targetUrl: nil
        )
        let connection = makeConnection([node])
        let results = connection.toDomain()
        #expect(results.isEmpty)
    }

    @Test("a page maps every node; duplicates stay until deduplicatedLatest")
    func pageMappingKeepsDuplicates() {
        let connection = makeConnection([
            makeStatusContextNode(context: "CI", state: "SUCCESS"),
            makeCheckRunNode(name: "CI", status: "COMPLETED", conclusion: "FAILURE"),
        ])
        let results = connection.toDomain(pageOffset: 7)
        #expect(results.map(\.id) == ["check-7-CI", "status-8-CI"])
        #expect(results.map(\.isCommitStatus) == [false, true])
    }

    @Test("a check run beats a commit status of the same name whichever page each is on")
    func dedupeIndependentOfPageBoundaries() {
        let statusPage = makeConnection([makeStatusContextNode(context: "CI", state: "SUCCESS")])
        let checkRunPage = makeConnection([
            makeCheckRunNode(name: "CI", status: "COMPLETED", conclusion: "FAILURE", detailsUrl: "https://example.com"),
        ])
        let onePage = makeConnection([
            makeStatusContextNode(context: "CI", state: "SUCCESS"),
            makeCheckRunNode(name: "CI", status: "COMPLETED", conclusion: "FAILURE", detailsUrl: "https://example.com"),
        ]).toDomain().deduplicatedLatest()
        let statusFirst = (statusPage.toDomain() + checkRunPage.toDomain(pageOffset: 1)).deduplicatedLatest()
        let checkRunFirst = (checkRunPage.toDomain() + statusPage.toDomain(pageOffset: 1)).deduplicatedLatest()

        for results in [onePage, statusFirst, checkRunFirst] {
            #expect(results.count == 1)
            #expect(results.first?.conclusion == .failure)
            #expect(results.first?.detailsURL != nil)
        }
    }

    // MARK: - workflowRunID + startedAt dedupe

    @Test("two CheckRuns with same name and different workflowRunID both survive")
    func distinctWorkflowsSameNameBothKept() throws {
        let connection = makeConnection([
            makeCheckRunNode(name: "test", status: "COMPLETED", conclusion: "SUCCESS", workflowRunID: 1001, startedAt: "2024-01-15T10:00:00Z"),
            makeCheckRunNode(name: "test", status: "COMPLETED", conclusion: "FAILURE", workflowRunID: 1002, startedAt: "2024-01-15T11:00:00Z"),
        ])
        let results = connection.toDomain().deduplicatedLatest()
        #expect(results.count == 2)
        #expect(results.contains { $0.workflowRunID == 1001 && $0.conclusion == .success })
        #expect(results.contains { $0.workflowRunID == 1002 && $0.conclusion == .failure })
    }

    @Test("within a workflow, a later failure replaces an earlier success (re-run regression)")
    func laterFailureWinsOverEarlierSuccess() throws {
        let connection = makeConnection([
            makeCheckRunNode(name: "test", status: "COMPLETED", conclusion: "SUCCESS", workflowRunID: 1001, startedAt: "2024-01-15T10:00:00Z"),
            makeCheckRunNode(name: "test", status: "COMPLETED", conclusion: "FAILURE", workflowRunID: 1001, startedAt: "2024-01-15T11:30:00Z"),
        ])
        let results = connection.toDomain().deduplicatedLatest()
        #expect(results.count == 1)
        #expect(results[0].conclusion == .failure)
    }

    @Test("within a workflow, a later success replaces an earlier failure (re-run of failed job)")
    func laterSuccessWinsOverEarlierFailure() throws {
        let connection = makeConnection([
            makeCheckRunNode(name: "test", status: "COMPLETED", conclusion: "FAILURE", workflowRunID: 1001, startedAt: "2024-01-15T10:00:00Z"),
            makeCheckRunNode(name: "test", status: "COMPLETED", conclusion: "SUCCESS", workflowRunID: 1001, startedAt: "2024-01-15T11:30:00Z"),
        ])
        let results = connection.toDomain().deduplicatedLatest()
        #expect(results.count == 1)
        #expect(results[0].conclusion == .success)
    }

    @Test("missing startedAt falls back to conclusion priority")
    func missingStartedAtFallsBackToPriority() throws {
        let connection = makeConnection([
            makeCheckRunNode(name: "test", status: "COMPLETED", conclusion: "FAILURE", workflowRunID: 1001, startedAt: nil),
            makeCheckRunNode(name: "test", status: "COMPLETED", conclusion: "SUCCESS", workflowRunID: 1001, startedAt: nil),
        ])
        let results = connection.toDomain().deduplicatedLatest()
        #expect(results.count == 1)
        #expect(results[0].conclusion == .success)
    }

    @Test("StatusContext with no workflowRunID still dedupes by name alone")
    func statusContextDedupesByNameOnly() throws {
        let connection = makeConnection([
            makeStatusContextNode(context: "ci/build", state: "FAILURE"),
            makeStatusContextNode(context: "ci/build", state: "SUCCESS"),
        ])
        let results = connection.toDomain().deduplicatedLatest()
        #expect(results.count == 1)
        // Within a group both runs have nil startedAt, so the priority
        // tie-break keeps the SUCCESS.
        #expect(results[0].conclusion == .success)
    }

    @Test("CheckRun with workflowRunID coexists with StatusContext of same name")
    func checkRunAndStatusContextSameNameDistinct() throws {
        let connection = makeConnection([
            makeCheckRunNode(name: "CI", status: "COMPLETED", conclusion: "SUCCESS", workflowRunID: 1001, startedAt: "2024-01-15T10:00:00Z"),
            makeStatusContextNode(context: "CI", state: "FAILURE"),
        ])
        let results = connection.toDomain().deduplicatedLatest()
        // The CheckRun keys on ("CI", 1001); the StatusContext keys on
        // ("CI", nil). Different keys → both survive.
        #expect(results.count == 2)
    }
}

@Suite("CheckRun deduplicatedLatest")
struct CheckRunDeduplicationTests {

    private func make(
        name: String,
        conclusion: CheckRunConclusion?,
        workflowRunID: Int? = nil,
        startedAt: Date? = nil
    ) -> CheckRun {
        CheckRun(
            id: UUID().uuidString,
            name: name,
            status: .completed,
            conclusion: conclusion,
            detailsURL: nil,
            isRequired: false,
            workflowRunID: workflowRunID,
            startedAt: startedAt
        )
    }

    @Test("empty input returns empty")
    func emptyInput() {
        let result: [CheckRun] = [].deduplicatedLatest()
        #expect(result.isEmpty)
    }

    @Test("single run passes through")
    func singleRun() {
        let run = make(name: "CI", conclusion: .success)
        let result = [run].deduplicatedLatest()
        #expect(result.count == 1)
        #expect(result[0].name == "CI")
    }

    @Test("missing startedAt falls back to conclusion priority")
    func fallbackToPriority() {
        let failed = make(name: "CI", conclusion: .failure)
        let success = make(name: "CI", conclusion: .success)
        let result = [failed, success].deduplicatedLatest()
        #expect(result.count == 1)
        #expect(result[0].conclusion == .success)
    }

    @Test("in-progress beats success on priority tie-break")
    func inProgressBeatsSuccess() {
        let success = make(name: "CI", conclusion: .success)
        let inProgress = CheckRun(id: "ip", name: "CI", status: .inProgress, conclusion: nil, detailsURL: nil, isRequired: false, workflowRunID: nil, startedAt: nil)
        let result = [success, inProgress].deduplicatedLatest()
        #expect(result.count == 1)
        #expect(result[0].conclusion == nil)
    }

    @Test("preserves insertion order of groups")
    func preservesOrder() {
        let a = make(name: "Alpha", conclusion: .success)
        let b = make(name: "Beta", conclusion: .success)
        let c = make(name: "Charlie", conclusion: .success)
        let result = [a, b, c].deduplicatedLatest()
        #expect(result.map(\.name) == ["Alpha", "Beta", "Charlie"])
    }

    @Test("different names are all kept")
    func differentNamesKept() {
        let a = make(name: "CI", conclusion: .success)
        let b = make(name: "Lint", conclusion: .failure)
        let result = [a, b].deduplicatedLatest()
        #expect(result.count == 2)
    }

    @Test("distinct workflowRunIDs with same name both survive")
    func distinctWorkflowRunsKept() {
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = t1.addingTimeInterval(60)
        let a = make(name: "test", conclusion: .success, workflowRunID: 1001, startedAt: t1)
        let b = make(name: "test", conclusion: .failure, workflowRunID: 1002, startedAt: t2)
        let result = [a, b].deduplicatedLatest()
        #expect(result.count == 2)
    }

    @Test("later failure wins over earlier success within a workflow (the shipped bug)")
    func laterFailureWinsInWorkflow() {
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = t1.addingTimeInterval(3600)
        let success = make(name: "test", conclusion: .success, workflowRunID: 1001, startedAt: t1)
        let failure = make(name: "test", conclusion: .failure, workflowRunID: 1001, startedAt: t2)
        let result = [success, failure].deduplicatedLatest()
        #expect(result.count == 1)
        #expect(result[0].conclusion == .failure)
    }

    @Test("later success wins over earlier failure within a workflow (re-run of failed job)")
    func laterSuccessWinsInWorkflow() {
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = t1.addingTimeInterval(3600)
        let failure = make(name: "test", conclusion: .failure, workflowRunID: 1001, startedAt: t1)
        let success = make(name: "test", conclusion: .success, workflowRunID: 1001, startedAt: t2)
        let result = [failure, success].deduplicatedLatest()
        #expect(result.count == 1)
        #expect(result[0].conclusion == .success)
    }

    @Test("nil workflowRunID entries dedupe on name alone")
    func nilWorkflowRunIDDedupeByName() {
        let a = make(name: "ci/build", conclusion: .failure, workflowRunID: nil)
        let b = make(name: "ci/build", conclusion: .success, workflowRunID: nil)
        let result = [a, b].deduplicatedLatest()
        #expect(result.count == 1)
        #expect(result[0].conclusion == .success)
    }
}
