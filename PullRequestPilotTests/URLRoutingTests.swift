import Testing
import Foundation
@testable import PullRequestPilot

@MainActor
@Suite("URL Routing")
struct URLRoutingTests {

    private func makeDashboardViewModel(suiteName: String) throws -> DashboardViewModel {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = ViewsStore(defaults: defaults)
        let mockClient = MockGitHubClient()
        let localRepoService = LocalRepositoryService()
        return DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
    }

    // MARK: - DeepLinkRoute

    @Test("view deep link routes to selectView with the parsed UUID")
    func viewDeepLinkRoutes() throws {
        let viewID = UUID()
        let url = try #require(URL(string: "pullrequestpilot://view/\(viewID.uuidString)"))
        #expect(DeepLinkRoute.route(for: url) == .selectView(viewID))
    }

    @Test("view deep link with invalid UUID is not routed")
    func viewDeepLinkInvalidUUID() throws {
        let url = try #require(URL(string: "pullrequestpilot://view/not-a-uuid"))
        #expect(DeepLinkRoute.route(for: url) == nil)
    }

    @Test("view deep link without an ID is not routed")
    func viewDeepLinkMissingID() throws {
        let url = try #require(URL(string: "pullrequestpilot://view"))
        #expect(DeepLinkRoute.route(for: url) == nil)
    }

    @Test("non-view deep links are not routed", arguments: [
        "pullrequestpilot://pr?url=https%3A%2F%2Fgithub.com%2Fowner%2Frepo%2Fpull%2F42",
        "pullrequestpilot://pr?url=file:///Applications",
        "pullrequestpilot://pr?url=x-custom-scheme://payload",
        "pullrequestpilot://unknown/path",
        "https://view/00000000-0000-0000-0000-000000000000",
    ])
    func unroutableLinks(urlString: String) throws {
        let url = try #require(URL(string: urlString))
        #expect(DeepLinkRoute.route(for: url) == nil)
    }

    // MARK: - AppDelegate.selectView

    @Test("selectView dismisses Settings and selects the view")
    func selectViewDismissesSettings() throws {
        let viewModel = try makeDashboardViewModel(suiteName: "URLRoutingSelectView")
        let firstView = DashboardView(id: UUID(), title: "First", query: "is:pr")
        let secondView = DashboardView(id: UUID(), title: "Second", query: "is:pr author:@me")
        viewModel.addView(firstView)
        viewModel.addView(secondView)
        viewModel.showingSettings = true

        let delegate = AppDelegate()
        delegate.dashboardViewModel = viewModel
        delegate.selectView(secondView.id)

        #expect(viewModel.showingSettings == false)
        #expect(viewModel.selectedViewID == secondView.id)
    }
}
