import Testing
import Foundation
@testable import PullRequestPilot

@MainActor
@Suite("ReviewQueueViewModel", .keychainCleanup)
struct ReviewQueueViewModelTests {
    let mockClient = MockGitHubClient()
    let localRepoService = LocalRepositoryService()

    private struct Harness {
        let queue: ReviewQueueViewModel
        let dashboard: DashboardViewModel
        let detail: PRDetailViewModel
        let defaults: UserDefaults
    }

    private final class OpenedDirectories {
        var entries: [(directory: URL, application: URL)] = []
    }

    private func makeHarness(
        suiteName: String,
        installedBundleIDs: Set<String> = [],
        opened: OpenedDirectories = OpenedDirectories()
    ) throws -> Harness {
        let defaults = try #require(UserDefaults(suiteName: "ReviewQueueViewModelTests.\(suiteName)"))
        defaults.removePersistentDomain(forName: "ReviewQueueViewModelTests.\(suiteName)")
        let dashboard = DashboardViewModel(
            gitHubClient: mockClient,
            identity: IdentityActorTestFactory.make(github: mockClient),
            viewsStore: ViewsStore(defaults: defaults),
            localRepositoryService: localRepoService,
            defaults: defaults,
            notificationCenter: MockUserNotificationCenter(),
            widgetDestination: .temporary()
        )
        let detail = PRDetailViewModel(gitHubClient: mockClient)
        let launcher = ExternalEditorLauncher(
            locateApplication: { bundleID in
                installedBundleIDs.contains(bundleID) ? URL(fileURLWithPath: "/Applications/\(bundleID).app") : nil
            },
            openDirectory: { directory, application in
                opened.entries.append((directory, application))
            }
        )
        let queue = ReviewQueueViewModel(dashboard: dashboard, detail: detail, editorLauncher: launcher, defaults: defaults)
        return Harness(queue: queue, dashboard: dashboard, detail: detail, defaults: defaults)
    }

    private func addViews(_ harness: Harness, _ titles: [String]) -> [ViewDefinition] {
        let views = titles.map { ViewDefinition(id: UUID(), title: $0, query: "is:pr \($0.lowercased())") }
        views.forEach(harness.dashboard.addView)
        return views
    }

    // MARK: - Changing views

    @Test("showing a view from outside the list dismisses Settings and selects it")
    func showViewDismissesSettings() throws {
        let harness = try makeHarness(suiteName: "ShowView")
        let views = addViews(harness, ["First", "Second"])
        harness.dashboard.showingSettings = true

        #expect(harness.queue.showView(views[1].id))

        #expect(harness.dashboard.showingSettings == false)
        #expect(harness.dashboard.selectedViewID == views[1].id)
        #expect(harness.queue.editingQuery == views[1].query)
    }

    @Test("a link to a deleted view changes nothing")
    func showUnknownView() throws {
        let harness = try makeHarness(suiteName: "ShowUnknownView")
        let views = addViews(harness, ["First"])
        harness.dashboard.showingSettings = true

        #expect(!harness.queue.showView(UUID()))

        #expect(harness.dashboard.selectedViewID == views[0].id)
        #expect(harness.dashboard.showingSettings)
    }

    @Test("switching views closes the detail and shows the new view's query")
    func selectViewClosesDetail() async throws {
        let harness = try makeHarness(suiteName: "SelectView")
        let views = addViews(harness, ["First", "Second"])
        harness.queue.toggleSelection(of: try TestPullRequestFactory.make())
        harness.queue.editingQuery = "uncommitted"

        harness.queue.selectView(views[1].id)

        #expect(harness.detail.selectedPR == nil)
        #expect(harness.queue.editingQuery == views[1].query)
        harness.queue.selectPreviousView()
        #expect(harness.dashboard.selectedViewID == views[0].id)
        #expect(harness.queue.editingQuery == views[0].query)
    }

    @Test("a notification about one pull request opens its view and its detail")
    func notificationOpensPullRequest() async throws {
        let harness = try makeHarness(suiteName: "NotificationRoute")
        let views = addViews(harness, ["First", "Second"])
        await mockClient.setPullRequestsToReturn([try TestPullRequestFactory.make(id: "PR_7")])
        await harness.dashboard.refresh(viewID: views[1].id)

        #expect(harness.queue.showNotification(NotificationRoute(viewID: views[1].id, pullRequestID: "PR_7")))

        #expect(harness.dashboard.selectedViewID == views[1].id)
        #expect(harness.detail.selectedPR?.id == "PR_7")
    }

    @Test("a notification whose pull request left the list opens its view only")
    func notificationForGonePullRequest() async throws {
        let harness = try makeHarness(suiteName: "NotificationGone")
        let views = addViews(harness, ["First", "Second"])

        #expect(harness.queue.showNotification(NotificationRoute(viewID: views[1].id, pullRequestID: "PR_gone")))

        #expect(harness.dashboard.selectedViewID == views[1].id)
        #expect(harness.detail.selectedPR == nil)
    }

    // MARK: - Adding and deleting views

    @Test("a new view needs a title and a query")
    func canAddViewNeedsBothFields() throws {
        let harness = try makeHarness(suiteName: "CanAdd")
        harness.queue.beginAddingView()
        harness.queue.newViewTitle = "  "
        harness.queue.newViewQuery = "is:pr"
        #expect(!harness.queue.canAddView)
        harness.queue.newViewTitle = "Mine"
        #expect(harness.queue.canAddView)
    }

    @Test("adding a view trims it, selects it, closes the form and loads it")
    func addViewSelectsAndLoads() async throws {
        let harness = try makeHarness(suiteName: "AddView")
        _ = addViews(harness, ["First"])
        await mockClient.setPullRequestsToReturn([try TestPullRequestFactory.make(id: "PR_new")])
        harness.queue.beginAddingView()
        harness.queue.newViewTitle = " Mine "
        harness.queue.newViewQuery = " is:pr author:@me "

        harness.queue.addView()

        let added = try #require(harness.queue.selectedView)
        #expect(added.title == "Mine")
        #expect(added.query == "is:pr author:@me")
        #expect(!harness.queue.isAddingView)
        #expect(harness.queue.editingQuery == "is:pr author:@me")
        try await TestWait.until { harness.dashboard.selectedViewState.pullRequests.map(\.id) == ["PR_new"] }
        #expect(harness.dashboard.selectedViewState.pullRequests.map(\.id) == ["PR_new"])
    }

    @Test("deleting the selected view moves to the next one and closes the detail")
    func confirmDeletionOfSelectedView() throws {
        let harness = try makeHarness(suiteName: "DeleteSelected")
        let views = addViews(harness, ["First", "Second"])
        harness.queue.toggleSelection(of: try TestPullRequestFactory.make())

        harness.queue.requestDeletionOfSelectedView()
        #expect(harness.queue.viewPendingDeletion == views[0])
        harness.queue.confirmDeletion()

        #expect(harness.dashboard.views == [views[1]])
        #expect(harness.dashboard.selectedViewID == views[1].id)
        #expect(harness.queue.editingQuery == views[1].query)
        #expect(harness.detail.selectedPR == nil)
        #expect(harness.queue.viewPendingDeletion == nil)
    }

    @Test("cancelling a deletion keeps the view")
    func cancelDeletion() throws {
        let harness = try makeHarness(suiteName: "DeleteCancel")
        let views = addViews(harness, ["First"])

        harness.queue.requestDeletion(of: views[0])
        harness.queue.cancelDeletion()
        harness.queue.confirmDeletion()

        #expect(harness.dashboard.views == views)
    }

    // MARK: - Query

    @Test("an empty commit puts the active query back in the field")
    func emptyCommitReverts() throws {
        let harness = try makeHarness(suiteName: "EmptyCommit")
        let views = addViews(harness, ["First"])
        harness.queue.editingQuery = "   "

        harness.queue.commitQueryEdit()

        #expect(harness.queue.editingQuery == views[0].query)
        #expect(harness.dashboard.views[0].query == views[0].query)
    }

    @Test("a filter from a menu shows up in the field and disables its menu item")
    func appendFilterSyncsField() throws {
        let harness = try makeHarness(suiteName: "AppendFilter")
        _ = addViews(harness, ["First"])

        harness.queue.appendFilter(.repo("acme/web"))

        #expect(harness.queue.editingQuery == "is:pr first repo:acme/web")
        #expect(harness.queue.isFilterApplied(.repo("acme/web")))
        #expect(!harness.queue.isFilterApplied(SearchQualifier.repo("acme/web").excluded))
    }

    // MARK: - Loading

    @Test("refresh reloads the open pull request's detail without closing it")
    func refreshKeepsDetailOpen() async throws {
        let harness = try makeHarness(suiteName: "RefreshDetail")
        let views = addViews(harness, ["First"])
        let pr = try TestPullRequestFactory.make(id: "PR_open")
        await mockClient.setPullRequestsToReturn([pr])
        await harness.dashboard.refresh(viewID: views[0].id)
        harness.queue.toggleSelection(of: pr)
        await harness.detail.waitForCurrentLoad()
        let timelineFetches = await mockClient.fetchTimelineCallCount

        await harness.queue.refresh()
        await harness.detail.waitForCurrentLoad()

        #expect(harness.detail.selectedPR?.id == "PR_open")
        #expect(await mockClient.fetchTimelineCallCount == timelineFetches + 1)
    }

    @Test("a failed page waits for Retry instead of reloading on every appearance")
    func loadMoreWaitsAfterFailure() async throws {
        let harness = try makeHarness(suiteName: "LoadMoreRetry")
        let views = addViews(harness, ["First"])
        await mockClient.setPullRequestsToReturn([try TestPullRequestFactory.make(id: "PR_1")])
        await mockClient.setNextCursorToReturn("cursor-1")
        await harness.dashboard.refresh(viewID: views[0].id)
        await mockClient.setErrorToThrow(GitHubClientError.serverError(statusCode: 502))
        await harness.queue.loadMoreIfPossible()
        #expect(harness.dashboard.selectedViewState.loadMoreFailed)
        let fetchesAfterFailure = await mockClient.fetchPullRequestsCallCount

        await harness.queue.loadMoreIfPossible()
        #expect(await mockClient.fetchPullRequestsCallCount == fetchesAfterFailure)

        await mockClient.setErrorToThrow(nil)
        await mockClient.setPullRequestsToReturn([try TestPullRequestFactory.make(id: "PR_2")])
        await mockClient.setNextCursorToReturn(nil)
        await harness.queue.retryLoadMore()
        #expect(harness.dashboard.selectedViewState.pullRequests.map(\.id) == ["PR_1", "PR_2"])
        #expect(!harness.dashboard.selectedViewState.loadMoreFailed)
    }

    @Test("Show Reviewed turns the view's hide-reviewed filter off")
    func showReviewed() throws {
        let harness = try makeHarness(suiteName: "ShowReviewed")
        let view = ViewDefinition(id: UUID(), title: "Mine", query: "is:pr", hideReviewed: true)
        harness.dashboard.addView(view)

        harness.queue.showReviewedPullRequests()

        #expect(harness.queue.selectedView?.hideReviewed == false)
    }

    // MARK: - Detail

    @Test("the detail follows the list: updated when the row changes, closed when it leaves")
    func reconcileSelection() async throws {
        let harness = try makeHarness(suiteName: "Reconcile")
        let views = addViews(harness, ["First"])
        let original = try TestPullRequestFactory.make(id: "PR_1", title: "Before")
        await mockClient.setPullRequestsToReturn([original])
        await harness.dashboard.refresh(viewID: views[0].id)
        harness.queue.toggleSelection(of: original)

        await mockClient.setPullRequestsToReturn([try TestPullRequestFactory.make(id: "PR_1", title: "After")])
        await harness.dashboard.refresh(viewID: views[0].id)
        harness.queue.reconcileSelection()
        #expect(harness.detail.selectedPR?.title == "After")

        await mockClient.setPullRequestsToReturn([])
        await harness.dashboard.refresh(viewID: views[0].id)
        harness.queue.reconcileSelection()
        #expect(harness.detail.selectedPR == nil)
    }

    @Test("collapsing the org that holds the open pull request closes its detail")
    func collapsingOrgClosesDetail() throws {
        let harness = try makeHarness(suiteName: "CollapseOrg")
        _ = addViews(harness, ["First"])
        let pr = try TestPullRequestFactory.make(repository: Repository(nameWithOwner: "acme/web"))
        harness.queue.toggleSelection(of: pr)

        harness.queue.toggleOrg("other")
        #expect(harness.detail.selectedPR != nil)
        harness.queue.toggleRepo(org: "acme", repo: "api")
        #expect(harness.detail.selectedPR != nil)

        harness.queue.toggleRepo(org: "acme", repo: "web")
        #expect(harness.queue.isRepoCollapsed(org: "acme", repo: "web"))
        #expect(harness.detail.selectedPR == nil)

        harness.queue.toggleRepo(org: "acme", repo: "web")
        #expect(!harness.queue.isRepoCollapsed(org: "acme", repo: "web"))
    }

    @Test("only stacks of two or more expand")
    func stackExpansion() throws {
        let harness = try makeHarness(suiteName: "Stacks")
        let root = try TestPullRequestFactory.make(id: "PR_root", headRefName: "a")
        let child = try TestPullRequestFactory.make(id: "PR_child", baseRefName: "a", headRefName: "b")
        let stacks = PRGrouping.buildStacks([root, child])
        let single = PRGrouping.buildStacks([try TestPullRequestFactory.make(id: "PR_alone")])

        harness.queue.toggleStack(stacks[0])
        harness.queue.toggleStack(single[0])

        #expect(harness.queue.isStackExpanded(stacks[0]))
        #expect(!harness.queue.isStackExpanded(single[0]))
    }

    @Test("the detail pane's size is saved and restored")
    func detailPanelSizePersists() throws {
        let harness = try makeHarness(suiteName: "PanelSize")
        harness.queue.detailPanelWidth = 612
        harness.queue.detailPanelHeight = 244
        harness.queue.saveDetailPanelSize()

        let restored = ReviewQueueViewModel(
            dashboard: harness.dashboard,
            detail: harness.detail,
            editorLauncher: ExternalEditorLauncher(),
            defaults: harness.defaults
        )

        #expect(restored.detailPanelWidth == 612)
        #expect(restored.detailPanelHeight == 244)
    }

    // MARK: - Local checkout

    @Test("only installed editors are offered, in menu order")
    func installedEditors() throws {
        let harness = try makeHarness(
            suiteName: "InstalledEditors",
            installedBundleIDs: [ExternalEditor.cmux.bundleIdentifier, ExternalEditor.visualStudioCode.bundleIdentifier]
        )
        #expect(harness.queue.installedEditors == [.visualStudioCode, .cmux])
    }

    @Test("a pull request opens in an editor at its local checkout, and not without one")
    func openInEditor() async throws {
        let opened = OpenedDirectories()
        let harness = try makeHarness(
            suiteName: "OpenInEditor",
            installedBundleIDs: [ExternalEditor.iTerm.bundleIdentifier],
            opened: opened
        )
        let checkout = URL(fileURLWithPath: "/Users/me/src/web")
        localRepoService.repoIndex = [
            LocalRepositoryService.RepoEntry(path: checkout, nameWithOwner: "acme/web", currentBranch: "feature-1", commitShas: [], worktrees: [])
        ]
        let local = try TestPullRequestFactory.make(repository: Repository(nameWithOwner: "acme/web"), headRefName: "feature-1")
        let elsewhere = try TestPullRequestFactory.make(repository: Repository(nameWithOwner: "acme/api"))

        await harness.queue.open(elsewhere, in: .iTerm)
        #expect(opened.entries.isEmpty)

        await harness.queue.open(local, in: .iTerm)
        #expect(opened.entries.map(\.directory) == [checkout])
        #expect(opened.entries.map(\.application.lastPathComponent) == ["\(ExternalEditor.iTerm.bundleIdentifier).app"])
    }
}
