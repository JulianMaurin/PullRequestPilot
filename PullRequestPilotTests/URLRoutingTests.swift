import Testing
import Foundation
@testable import PullRequestPilot

@MainActor
@Suite("URL Routing")
struct URLRoutingTests {

    private func makeDashboardViewModel(suiteName: String) -> DashboardViewModel {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = ViewsStore(defaults: defaults)
        let mockClient = MockGitHubClient()
        let localRepoService = LocalRepositoryService()
        return DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
    }

    @Test("view deep link sets selectedViewID")
    func viewDeepLink() {
        let viewModel = makeDashboardViewModel(suiteName: "URLRoutingView")
        let view = DashboardView(id: UUID(), title: "Test View", query: "is:pr")
        viewModel.addView(view)

        // Simulate the URL handling logic from PullRequestPilotApp
        let url = URL(string: "pullrequestpilot://view/\(view.id.uuidString)")!
        #expect(url.scheme == "pullrequestpilot")
        #expect(url.host == "view")

        if let viewID = url.pathComponents.dropFirst().first,
           let uuid = UUID(uuidString: viewID) {
            viewModel.selectedViewID = uuid
        }

        #expect(viewModel.selectedViewID == view.id)
    }

    @Test("view deep link with invalid UUID is ignored")
    func viewDeepLinkInvalidUUID() {
        let viewModel = makeDashboardViewModel(suiteName: "URLRoutingInvalid")
        let view = DashboardView(id: UUID(), title: "Test View", query: "is:pr")
        viewModel.addView(view)
        let originalSelection = viewModel.selectedViewID

        let url = URL(string: "pullrequestpilot://view/not-a-uuid")!
        if let viewID = url.pathComponents.dropFirst().first,
           let uuid = UUID(uuidString: viewID) {
            viewModel.selectedViewID = uuid
        }

        // Selection should not change
        #expect(viewModel.selectedViewID == originalSelection)
    }

    @Test("pr deep link extracts correct URL")
    func prDeepLink() {
        let url = URL(string: "pullrequestpilot://pr?url=https%3A%2F%2Fgithub.com%2Fowner%2Frepo%2Fpull%2F42")!
        #expect(url.scheme == "pullrequestpilot")
        #expect(url.host == "pr")

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let prURLString = components?.queryItems?.first(where: { $0.name == "url" })?.value
        #expect(prURLString == "https://github.com/owner/repo/pull/42")
        let prURL = prURLString.flatMap(URL.init(string:))
        #expect(prURL != nil)
    }

    @Test("unknown scheme host is ignored")
    func unknownHost() {
        let url = URL(string: "pullrequestpilot://unknown/path")!
        #expect(url.host == "unknown")
        // Just verify parsing works without crash
    }
}
