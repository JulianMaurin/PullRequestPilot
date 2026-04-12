import Testing
import Foundation
@testable import PullRequestPilot

@MainActor
@Suite("DashboardViewModel.commitQueryEdit & appendFilter")
struct QueryEditTests {
    private let mockClient = MockGitHubClient()
    private let localRepoService = LocalRepositoryService()

    private func makeViewModel(suiteName: String) -> DashboardViewModel {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = ViewsStore(defaults: defaults)
        let vm = DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        let view = DashboardView(id: UUID(), title: "Test", query: "is:pr is:open")
        vm.addView(view)
        return vm
    }

    // MARK: - commitQueryEdit

    @Test("commitQueryEdit updates query when trimmed value differs")
    func commitQueryEditUpdates() {
        let vm = makeViewModel(suiteName: "QEditUpdates")
        let viewID = vm.views.first!.id
        vm.commitQueryEdit(viewID: viewID, newQuery: "is:pr author:@me")
        #expect(vm.views.first!.query == "is:pr author:@me")
    }

    @Test("commitQueryEdit trims whitespace")
    func commitQueryEditTrims() {
        let vm = makeViewModel(suiteName: "QEditTrims")
        let viewID = vm.views.first!.id
        vm.commitQueryEdit(viewID: viewID, newQuery: "  is:pr author:@me  \n")
        #expect(vm.views.first!.query == "is:pr author:@me")
    }

    @Test("commitQueryEdit is no-op when empty after trim")
    func commitQueryEditIgnoresEmpty() {
        let vm = makeViewModel(suiteName: "QEditEmpty")
        let viewID = vm.views.first!.id
        let original = vm.views.first!.query
        vm.commitQueryEdit(viewID: viewID, newQuery: "   ")
        #expect(vm.views.first!.query == original)
    }

    @Test("commitQueryEdit is no-op when query unchanged")
    func commitQueryEditIgnoresSame() {
        let vm = makeViewModel(suiteName: "QEditSame")
        let viewID = vm.views.first!.id
        let original = vm.views.first!.query
        mockClient.fetchPullRequestsCallCount = 0
        vm.commitQueryEdit(viewID: viewID, newQuery: original)
        // No refresh should be triggered since query didn't change
        #expect(vm.views.first!.query == original)
    }

    @Test("commitQueryEdit is no-op for invalid viewID")
    func commitQueryEditInvalidView() {
        let vm = makeViewModel(suiteName: "QEditInvalid")
        vm.commitQueryEdit(viewID: UUID(), newQuery: "is:pr")
        // Should not crash or modify any view
        #expect(vm.views.first!.query == "is:pr is:open")
    }

    // MARK: - appendFilter

    @Test("appendFilter appends qualifier to query")
    func appendFilterAppends() {
        let vm = makeViewModel(suiteName: "FilterAppend")
        let viewID = vm.views.first!.id
        vm.appendFilter(viewID: viewID, qualifier: "org:acme")
        #expect(vm.views.first!.query == "is:pr is:open org:acme")
    }

    @Test("appendFilter skips if qualifier already present")
    func appendFilterSkipsDuplicate() {
        let vm = makeViewModel(suiteName: "FilterDup")
        let viewID = vm.views.first!.id
        vm.appendFilter(viewID: viewID, qualifier: "is:pr")
        // "is:pr" is already in the query, should not be added again
        #expect(vm.views.first!.query == "is:pr is:open")
    }

    @Test("appendFilter is no-op for invalid viewID")
    func appendFilterInvalidView() {
        let vm = makeViewModel(suiteName: "FilterInvalid")
        vm.appendFilter(viewID: UUID(), qualifier: "org:acme")
        #expect(vm.views.first!.query == "is:pr is:open")
    }
}
