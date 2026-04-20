import Testing
import Foundation
@testable import PullRequestPilot

@MainActor
@Suite("DashboardViewModel.commitQueryEdit & appendFilter")
struct QueryEditTests {
    private let mockClient = MockGitHubClient()
    private let localRepoService = LocalRepositoryService()

    private func makeViewModel(suiteName: String) -> (vm: DashboardViewModel, viewID: UUID) {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = ViewsStore(defaults: defaults)
        let vm = DashboardViewModel(gitHubClient: mockClient, identity: IdentityActorTestFactory.make(github: mockClient), viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
        let view = DashboardView(id: UUID(), title: "Test", query: "is:pr is:open")
        vm.addView(view)
        return (vm, view.id)
    }

    // MARK: - commitQueryEdit

    @Test("commitQueryEdit updates query when trimmed value differs")
    func commitQueryEditUpdates() {
        let (vm, viewID) = makeViewModel(suiteName: "QEditUpdates")
        vm.commitQueryEdit(viewID: viewID, newQuery: "is:pr author:@me")
        #expect(vm.views.first(where: { $0.id == viewID })?.query == "is:pr author:@me")
    }

    @Test("commitQueryEdit trims whitespace")
    func commitQueryEditTrims() {
        let (vm, viewID) = makeViewModel(suiteName: "QEditTrims")
        vm.commitQueryEdit(viewID: viewID, newQuery: "  is:pr author:@me  \n")
        #expect(vm.views.first(where: { $0.id == viewID })?.query == "is:pr author:@me")
    }

    @Test("commitQueryEdit is no-op when empty after trim")
    func commitQueryEditIgnoresEmpty() {
        let (vm, viewID) = makeViewModel(suiteName: "QEditEmpty")
        let original = vm.views.first(where: { $0.id == viewID })?.query
        vm.commitQueryEdit(viewID: viewID, newQuery: "   ")
        #expect(vm.views.first(where: { $0.id == viewID })?.query == original)
    }

    @Test("commitQueryEdit is no-op when query unchanged")
    func commitQueryEditIgnoresSame() async {
        let (vm, viewID) = makeViewModel(suiteName: "QEditSame")
        let original = vm.views.first(where: { $0.id == viewID })?.query ?? ""
        await mockClient.setFetchPullRequestsCallCount(0)
        vm.commitQueryEdit(viewID: viewID, newQuery: original)
        #expect(vm.views.first(where: { $0.id == viewID })?.query == original)
    }

    @Test("commitQueryEdit is no-op for invalid viewID")
    func commitQueryEditInvalidView() {
        let (vm, viewID) = makeViewModel(suiteName: "QEditInvalid")
        vm.commitQueryEdit(viewID: UUID(), newQuery: "is:pr")
        #expect(vm.views.first(where: { $0.id == viewID })?.query == "is:pr is:open")
    }

    // MARK: - appendFilter

    @Test("appendFilter appends qualifier to query")
    func appendFilterAppends() {
        let (vm, viewID) = makeViewModel(suiteName: "FilterAppend")
        vm.appendFilter(viewID: viewID, qualifier: "org:acme")
        #expect(vm.views.first(where: { $0.id == viewID })?.query == "is:pr is:open org:acme")
    }

    @Test("appendFilter skips if qualifier already present")
    func appendFilterSkipsDuplicate() {
        let (vm, viewID) = makeViewModel(suiteName: "FilterDup")
        vm.appendFilter(viewID: viewID, qualifier: "is:pr")
        #expect(vm.views.first(where: { $0.id == viewID })?.query == "is:pr is:open")
    }

    @Test("appendFilter is no-op for invalid viewID")
    func appendFilterInvalidView() {
        let (vm, viewID) = makeViewModel(suiteName: "FilterInvalid")
        vm.appendFilter(viewID: UUID(), qualifier: "org:acme")
        #expect(vm.views.first(where: { $0.id == viewID })?.query == "is:pr is:open")
    }

    // MARK: - queryContainsFilter

    @Test("queryContainsFilter returns true when qualifier exists")
    func queryContainsFilterTrue() {
        let (vm, viewID) = makeViewModel(suiteName: "ContainsFilterTrue")
        vm.selectedViewID = viewID
        #expect(vm.queryContainsFilter(qualifier: "is:pr"))
    }

    @Test("queryContainsFilter returns false when qualifier absent")
    func queryContainsFilterFalse() {
        let (vm, viewID) = makeViewModel(suiteName: "ContainsFilterFalse")
        vm.selectedViewID = viewID
        #expect(!vm.queryContainsFilter(qualifier: "org:acme"))
    }

    @Test("queryContainsFilter returns false when no view selected")
    func queryContainsFilterNoSelection() {
        let (vm, _) = makeViewModel(suiteName: "ContainsFilterNone")
        vm.selectedViewID = nil
        #expect(!vm.queryContainsFilter(qualifier: "is:pr"))
    }
}
