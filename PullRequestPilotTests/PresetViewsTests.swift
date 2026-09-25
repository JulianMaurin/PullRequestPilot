import Testing
import Foundation
@testable import PullRequestPilot

@MainActor
@Suite("DashboardViewModel.presetViews")
struct PresetViewsTests {
    private let mockClient = MockGitHubClient()
    private let localRepoService = LocalRepositoryService()

    private func makeViewModel(suiteName: String) throws -> DashboardViewModel {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = ViewsStore(defaults: defaults)
        return DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults, notificationCenter: MockUserNotificationCenter(), widgetDestination: .temporary())
    }

    @Test("presets don't pin a base branch, so repos on master or develop still match")
    func presetsHaveNoBaseQualifier() {
        for preset in ViewDefinition.presetViews {
            #expect(!preset.query.contains("base:"), "\(preset.title) pins a base branch")
        }
    }

    // MARK: - Adding and resetting

    @Test("adding a preset copies it under a new ID, selects it and loads it")
    func addPresetViewLoads() async throws {
        let viewModel = try makeViewModel(suiteName: "AddPreset")
        let preset = ViewDefinition.presetViews[1]
        await mockClient.setPullRequestsToReturn([try TestPullRequestFactory.make(id: "PR_preset")])

        viewModel.addPresetView(preset)

        let added = try #require(viewModel.views.first)
        #expect(added.title == preset.title)
        #expect(added.query == preset.query)
        #expect(added.hideReviewed == preset.hideReviewed)
        #expect(added.id != preset.id)
        #expect(viewModel.selectedViewID == added.id)
        try await TestWait.until { viewModel.viewStates[added.id]?.pullRequests.map(\.id) == ["PR_preset"] }
        #expect(viewModel.viewStates[added.id]?.pullRequests.map(\.id) == ["PR_preset"])
    }

    @Test("resetting a preset restores its query and filter, keeps the view's ID and reloads it")
    func resetPresetView() async throws {
        let viewModel = try makeViewModel(suiteName: "ResetPreset")
        let preset = ViewDefinition.presetViews[1]
        let viewID = UUID()
        viewModel.addView(ViewDefinition(id: viewID, title: preset.title, query: "is:pr author:someone", hideReviewed: !preset.hideReviewed))
        await mockClient.setPullRequestsToReturn([try TestPullRequestFactory.make(id: "PR_old")])
        await viewModel.refresh(viewID: viewID)
        await mockClient.setPullRequestsToReturn([try TestPullRequestFactory.make(id: "PR_reset")])

        viewModel.resetPresetView(preset)

        let reset = try #require(viewModel.views.first { $0.id == viewID })
        #expect(reset.query == preset.query)
        #expect(reset.hideReviewed == preset.hideReviewed)
        try await TestWait.until { viewModel.viewStates[viewID]?.pullRequests.map(\.id) == ["PR_reset"] }
        #expect(viewModel.viewStates[viewID]?.pullRequests.map(\.id) == ["PR_reset"])
        #expect(await mockClient.receivedQueries.last == preset.query)
    }

    @Test("resetting a preset without a view of that name changes nothing")
    func resetMissingPreset() throws {
        let viewModel = try makeViewModel(suiteName: "ResetMissingPreset")
        viewModel.resetPresetView(ViewDefinition.presetViews[0])
        #expect(viewModel.views.isEmpty)
    }
}
