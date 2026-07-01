import Testing
import Foundation
@testable import PullRequestPilot

@MainActor
@Suite("DashboardViewModel.widgetData")
struct WidgetDataMappingTests {
    private let mockClient = MockGitHubClient()
    private let localRepoService = LocalRepositoryService()

    private func makeViewModel(suiteName: String) -> (DashboardViewModel, UUID) {
        // Redirect widget writes to a per-test file: DashboardViewModel builds
        // its own WidgetSync, so the process-global seam is the only injection
        // point. Never reset — no later write may reach the real app-group
        // container.
        let widgetFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("widget-mapping-\(suiteName)-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("widget-data.json")
        WidgetData.setStorageURLOverride(widgetFileURL)
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        let testView = DashboardView(id: UUID(), title: "Widget Test", query: "is:pr")
        viewModel.addView(testView)
        return (viewModel, testView.id)
    }

    @Test("refreshAll updates widget data with PR counts")
    func widgetDataCounts() async {
        let (viewModel, _) = makeViewModel(suiteName: "WidgetCounts")

        let pr1 = TestPullRequestFactory.make(id: "PR_1", reviewDecision: .approved)
        let pr2 = TestPullRequestFactory.make(id: "PR_2", reviewDecision: .changesRequested)
        let pr3 = TestPullRequestFactory.make(id: "PR_3", reviewDecision: .reviewRequired)
        await mockClient.setPullRequestsToReturn([pr1, pr2, pr3])

        await viewModel.refreshAll()

        let widgetData = WidgetData.load()
        let widgetView = widgetData?.views.first(where: { $0.title == "Widget Test" })
        #expect(widgetView != nil)
        #expect(widgetView?.count == 3)
        #expect(widgetView?.approvedCount == 1)
        #expect(widgetView?.changesRequestedCount == 1)
    }

    @Test("widget data limits PRs to 10 per view")
    func widgetDataLimitsPRs() async {
        let (viewModel, _) = makeViewModel(suiteName: "WidgetLimit")

        await mockClient.setPullRequestsToReturn((1...15).map {
            TestPullRequestFactory.make(id: "PR_\($0)", number: $0, title: "PR \($0)")
        })

        await viewModel.refreshAll()

        let widgetData = WidgetData.load()
        let widgetView = widgetData?.views.first(where: { $0.title == "Widget Test" })
        #expect(widgetView?.count == 15)
        #expect(widgetView?.pullRequests.count == 10)
    }

    @Test("widget data maps PR fields correctly")
    func widgetDataFields() async {
        let (viewModel, _) = makeViewModel(suiteName: "WidgetFields")
        let pr = TestPullRequestFactory.make(
            id: "PR_42",
            number: 42,
            title: "Add feature",
            repository: Repository(nameWithOwner: "org/repo"),
            author: Author(login: "dev", avatarURL: nil),
            isDraft: true,
            reviewDecision: .approved
        )
        await mockClient.setPullRequestsToReturn([pr])

        await viewModel.refreshAll()

        let widgetData = WidgetData.load()
        let widgetPR = widgetData?.views.first?.pullRequests.first
        #expect(widgetPR?.number == 42)
        #expect(widgetPR?.title == "Add feature")
        #expect(widgetPR?.repositoryName == "org/repo")
        #expect(widgetPR?.authorLogin == "dev")
        #expect(widgetPR?.isDraft == true)
        #expect(widgetPR?.reviewDecision == "APPROVED")
    }

    @Test("clearAllData writes empty widget data")
    func clearAllDataClearsWidget() async {
        let (viewModel, _) = makeViewModel(suiteName: "WidgetClear")
        await mockClient.setPullRequestsToReturn([TestPullRequestFactory.make()])

        await viewModel.refreshAll()
        viewModel.clearAllData()

        let widgetData = WidgetData.load()
        #expect(widgetData?.views.isEmpty == true)
    }
}
