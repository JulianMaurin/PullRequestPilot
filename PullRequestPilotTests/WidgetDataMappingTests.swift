import Testing
import Foundation
@testable import PullRequestPilot

@MainActor
@Suite("DashboardViewModel.widgetData")
struct WidgetDataMappingTests {
    private let mockClient = MockGitHubClient()
    private let localRepoService = LocalRepositoryService()

    /// Returns the file the view model writes widget data to.
    private func makeViewModel(suiteName: String) throws -> (DashboardViewModel, URL) {
        let destination = WidgetDestination.temporary()
        let widgetFileURL = try #require(destination.fileURL)
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = ViewsStore(defaults: defaults)
        let viewModel = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults, notificationCenter: MockUserNotificationCenter(), widgetDestination: destination)
        viewModel.addView(ViewDefinition(id: UUID(), title: "Widget Test", query: "is:pr"))
        return (viewModel, widgetFileURL)
    }

    @Test("refreshAll updates widget data with PR counts")
    func widgetDataCounts() async throws {
        let (viewModel, widgetFileURL) = try makeViewModel(suiteName: "WidgetCounts")

        let pr1 = try TestPullRequestFactory.make(id: "PR_1", reviewDecision: .approved)
        let pr2 = try TestPullRequestFactory.make(id: "PR_2", reviewDecision: .changesRequested)
        let pr3 = try TestPullRequestFactory.make(id: "PR_3", reviewDecision: .reviewRequired)
        await mockClient.setPullRequestsToReturn([pr1, pr2, pr3])

        await viewModel.refreshAll()

        let widgetData = WidgetData.load(from: widgetFileURL)
        let widgetView = widgetData?.views.first(where: { $0.title == "Widget Test" })
        #expect(widgetView != nil)
        #expect(widgetView?.count == 3)
        #expect(widgetView?.approvedCount == 1)
        #expect(widgetView?.changesRequestedCount == 1)
    }

    @Test("widget data limits PRs to 10 per view")
    func widgetDataLimitsPRs() async throws {
        let (viewModel, widgetFileURL) = try makeViewModel(suiteName: "WidgetLimit")

        try await mockClient.setPullRequestsToReturn((1...15).map {
            try TestPullRequestFactory.make(id: "PR_\($0)", number: $0, title: "PR \($0)")
        })

        await viewModel.refreshAll()

        let widgetData = WidgetData.load(from: widgetFileURL)
        let widgetView = widgetData?.views.first(where: { $0.title == "Widget Test" })
        #expect(widgetView?.count == 15)
        #expect(widgetView?.pullRequests.count == 10)
    }

    @Test("widget data maps PR fields correctly")
    func widgetDataFields() async throws {
        let (viewModel, widgetFileURL) = try makeViewModel(suiteName: "WidgetFields")
        let pr = try TestPullRequestFactory.make(
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

        let widgetData = WidgetData.load(from: widgetFileURL)
        let widgetPR = widgetData?.views.first?.pullRequests.first
        #expect(widgetPR?.number == 42)
        #expect(widgetPR?.title == "Add feature")
        #expect(widgetPR?.repositoryName == "org/repo")
        #expect(widgetPR?.authorLogin == "dev")
        #expect(widgetPR?.isDraft == true)
        #expect(widgetPR?.reviewDecision == .approved)
    }

    @Test("clearAllData writes empty widget data")
    func clearAllDataClearsWidget() async throws {
        let (viewModel, widgetFileURL) = try makeViewModel(suiteName: "WidgetClear")
        await mockClient.setPullRequestsToReturn([try TestPullRequestFactory.make()])

        await viewModel.refreshAll()
        viewModel.clearAllData()

        let widgetData = WidgetData.load(from: widgetFileURL)
        #expect(widgetData?.views.isEmpty == true)
    }
}
