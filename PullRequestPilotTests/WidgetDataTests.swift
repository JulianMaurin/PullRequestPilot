import Testing
import Foundation
@testable import PullRequestPilot

@Suite("WidgetData")
struct WidgetDataTests {

    // MARK: - compactAge

    private func makeWidgetPR(createdAt: Date = Date()) -> WidgetPullRequest {
        WidgetPullRequest(
            id: "PR_1",
            number: 1,
            title: "Test",
            url: URL(string: "https://github.com/owner/repo/pull/1")!,
            repositoryName: "owner/repo",
            authorLogin: "author",
            createdAt: createdAt,
            reviewDecision: nil,
            checkStatus: nil,
            isDraft: false,
            state: "OPEN"
        )
    }

    @Test("compactAge shows minutes for < 60 minutes")
    func compactAgeMinutes() {
        let pr = makeWidgetPR(createdAt: Date.now.addingTimeInterval(-45 * 60))
        #expect(pr.compactAge == "45m")
    }

    @Test("compactAge shows 0m for just created")
    func compactAgeZeroMinutes() {
        let pr = makeWidgetPR(createdAt: Date.now)
        #expect(pr.compactAge == "0m")
    }

    @Test("compactAge shows hours for 1-23 hours")
    func compactAgeHours() {
        let pr = makeWidgetPR(createdAt: Date.now.addingTimeInterval(-5 * 3600))
        #expect(pr.compactAge == "5h")
    }

    @Test("compactAge shows 1h at exactly 60 minutes")
    func compactAgeOneHour() {
        let pr = makeWidgetPR(createdAt: Date.now.addingTimeInterval(-60 * 60))
        #expect(pr.compactAge == "1h")
    }

    @Test("compactAge shows days for 1-29 days")
    func compactAgeDays() {
        let pr = makeWidgetPR(createdAt: Date.now.addingTimeInterval(-3 * 86400))
        #expect(pr.compactAge == "3d")
    }

    @Test("compactAge shows 1d at exactly 24 hours")
    func compactAgeOneDay() {
        let pr = makeWidgetPR(createdAt: Date.now.addingTimeInterval(-24 * 3600))
        #expect(pr.compactAge == "1d")
    }

    @Test("compactAge shows months for >= 30 days")
    func compactAgeMonths() {
        let pr = makeWidgetPR(createdAt: Date.now.addingTimeInterval(-60 * 86400))
        #expect(pr.compactAge == "2mo")
    }

    @Test("compactAge shows 1mo at exactly 30 days")
    func compactAgeOneMonth() {
        let pr = makeWidgetPR(createdAt: Date.now.addingTimeInterval(-30 * 86400))
        #expect(pr.compactAge == "1mo")
    }

    // MARK: - repoShortName

    @Test("repoShortName extracts name after slash")
    func repoShortNameWithSlash() {
        let pr = WidgetPullRequest(
            id: "PR_1", number: 1, title: "Test",
            url: URL(string: "https://github.com/owner/my-repo/pull/1")!,
            repositoryName: "owner/my-repo",
            authorLogin: "author", createdAt: Date(),
            reviewDecision: nil, checkStatus: nil, isDraft: false, state: "OPEN"
        )
        #expect(pr.repoShortName == "my-repo")
    }

    @Test("repoShortName returns full name when no slash")
    func repoShortNameNoSlash() {
        let pr = WidgetPullRequest(
            id: "PR_1", number: 1, title: "Test",
            url: URL(string: "https://github.com/repo/pull/1")!,
            repositoryName: "standalone-repo",
            authorLogin: "author", createdAt: Date(),
            reviewDecision: nil, checkStatus: nil, isDraft: false, state: "OPEN"
        )
        #expect(pr.repoShortName == "standalone-repo")
    }

    // MARK: - WidgetViewData review counts

    private func makeViewData(reviewDecisions: [String?]) -> WidgetViewData {
        let prs = reviewDecisions.enumerated().map { index, decision in
            WidgetPullRequest(
                id: "PR_\(index)",
                number: index,
                title: "PR \(index)",
                url: URL(string: "https://github.com/owner/repo/pull/\(index)")!,
                repositoryName: "owner/repo",
                authorLogin: "author",
                createdAt: Date(),
                reviewDecision: decision,
                checkStatus: nil,
                isDraft: false,
                state: "OPEN"
            )
        }
        return WidgetViewData(id: "view1", title: "Test", count: prs.count, pullRequests: prs)
    }

    @Test("approvedCount filters correctly")
    func approvedCount() {
        let data = makeViewData(reviewDecisions: ["APPROVED", "CHANGES_REQUESTED", "APPROVED", nil])
        #expect(data.approvedCount == 2)
    }

    @Test("changesRequestedCount filters correctly")
    func changesRequestedCount() {
        let data = makeViewData(reviewDecisions: ["APPROVED", "CHANGES_REQUESTED", nil, "CHANGES_REQUESTED"])
        #expect(data.changesRequestedCount == 2)
    }

    @Test("pendingReviewCount is count minus approved and changesRequested")
    func pendingReviewCount() {
        let data = makeViewData(reviewDecisions: ["APPROVED", "CHANGES_REQUESTED", nil, nil, "REVIEW_REQUIRED"])
        #expect(data.pendingReviewCount == 3)
    }

    @Test("all counts are zero for empty pullRequests")
    func emptyCounts() {
        let data = WidgetViewData(id: "view1", title: "Test", count: 0, pullRequests: [])
        #expect(data.approvedCount == 0)
        #expect(data.changesRequestedCount == 0)
        #expect(data.pendingReviewCount == 0)
    }

    // MARK: - WidgetData Codable

    @Test("WidgetData encodes and decodes with secondsSince1970 dates")
    func codableRoundTrip() throws {
        let pr = makeWidgetPR(createdAt: Date(timeIntervalSince1970: 1700000000))
        let viewData = WidgetViewData(id: "v1", title: "View", count: 1, pullRequests: [pr])
        let widgetData = WidgetData(views: [viewData], lastUpdated: Date(timeIntervalSince1970: 1700000100))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(widgetData)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(WidgetData.self, from: data)

        #expect(decoded.views.count == 1)
        #expect(decoded.views[0].pullRequests[0].createdAt == Date(timeIntervalSince1970: 1700000000))
        #expect(decoded.lastUpdated == Date(timeIntervalSince1970: 1700000100))
    }

    // MARK: - WidgetPullRequest Hashable & Identifiable

    @Test("WidgetPullRequest uses id for identity")
    func identifiable() {
        let pr = makeWidgetPR()
        #expect(pr.id == "PR_1")
    }

    @Test("WidgetViewData Identifiable uses id")
    func viewDataIdentifiable() {
        let data = WidgetViewData(id: "test-id", title: "Test", count: 0, pullRequests: [])
        #expect(data.id == "test-id")
    }
}
