import AppKit
import Foundation
import os

struct ViewState: Sendable {
    var pullRequests: [PullRequest] = []
    var seenIDs: Set<String> = []
    var isLoading = false
    var isLoadingMore = false
    var error: String?
    var isNetworkError = false
    var nextCursor: String?
    var rateLimitRetryAfter: TimeInterval?
    var reachedLimit = false
    var rawFetchedCount = 0
    var skippedPRCount = 0

    var isEmpty: Bool { pullRequests.isEmpty && !isLoading }
    var hasData: Bool { !pullRequests.isEmpty }
    var canLoadMore: Bool { nextCursor != nil && !isLoadingMore && !reachedLimit }
}

@MainActor
@Observable
final class DashboardViewModel: DashboardActionsProtocol {

    // MARK: - Collaborators

    let viewRegistry: ViewRegistry
    let fetcher: PRFetcher
    let badgeTracker: BadgeTracker
    let notificationService: NotificationService
    private let scheduler: AutoRefreshScheduler
    private let widgetSync: WidgetSync

    // MARK: - UI state that belongs on the VM

    var showingSettings = false
    var collapsedOrgs: Set<String> {
        didSet { persistCollapsedSections() }
    }
    var collapsedRepos: Set<String> {
        didSet { persistCollapsedSections() }
    }

    // MARK: - Delegated view-registry state

    var views: [DashboardView] { viewRegistry.views }

    var selectedViewID: UUID? {
        get { viewRegistry.selectedViewID }
        set {
            viewRegistry.selectedViewID = newValue
            markBadgeAsSeenForSelectedView()
        }
    }

    // MARK: - Delegated fetcher state

    var viewStates: [UUID: ViewState] { fetcher.states }

    var selectedViewState: ViewState {
        guard let id = selectedViewID else { return ViewState() }
        return fetcher.state(for: id)
    }

    // MARK: - Infra

    private let gitHubClient: GitHubClientProtocol
    private let identity: IdentityActor
    private let localRepositoryService: LocalRepositoryService
    private let defaults: UserDefaults
    private let reporter: EventReporter
    private let pendingScheduledRefreshes = TaskMap()
    private let pendingSideEffectTasks = TaskMap()
    private var isRefreshingAll = false
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PullRequestPilot", category: "Dashboard")

    // MARK: - Init

    init(gitHubClient: GitHubClientProtocol, identity: IdentityActor, viewsStore: any ViewsStoreProtocol, localRepositoryService: LocalRepositoryService, defaults: UserDefaults, reporter: EventReporter = .noop) {
        self.gitHubClient = gitHubClient
        self.identity = identity
        self.localRepositoryService = localRepositoryService
        self.defaults = defaults
        self.reporter = reporter
        self.collapsedOrgs = Set(defaults.stringArray(forKey: Constants.UserDefaultsKeys.collapsedOrgs) ?? [])
        self.collapsedRepos = Set(defaults.stringArray(forKey: Constants.UserDefaultsKeys.collapsedRepos) ?? [])
        self.badgeTracker = BadgeTracker(defaults: defaults)
        self.notificationService = NotificationService(defaults: defaults, reporter: reporter)
        self.viewRegistry = ViewRegistry(viewsStore: viewsStore, defaults: defaults)

        let filterIdentity = identity
        let filterReporter = reporter
        let filterLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PullRequestPilot", category: "Dashboard.Filter")
        let filter: PRFetcher.PRFilter = { prs, view in
            guard view.hideReviewed else { return prs }
            let login: String?
            do {
                login = try await filterIdentity.currentViewerLogin()
            } catch is CancellationError {
                // Cancellation during view switch / auto-refresh restart — do
                // not treat as a user-visible failure. Return the unfiltered
                // list; the next refresh will produce the correct view.
                return prs
            } catch {
                filterLogger.warning("viewer login fetch failed: \(error, privacy: .public)")
                filterReporter.postError(.viewerIdentityUnavailable)
                return prs
            }
            guard let login else {
                filterLogger.warning("hideReviewed enabled but viewer login unavailable — skipping filter")
                filterReporter.postError(.viewerIdentityUnavailable)
                return prs
            }
            let filtered = prs.filter { pr in
                guard let viewerReview = pr.latestReviews.first(where: { $0.login == login }) else {
                    return true
                }
                return viewerReview.state == .dismissed
            }
            let removedCount = prs.count - filtered.count
            if removedCount > 0 {
                filterLogger.info("Filtered out \(removedCount, privacy: .public) reviewed PR(s) for '\(view.title, privacy: .public)'")
            }
            return filtered
        }
        self.fetcher = PRFetcher(gitHubClient: gitHubClient, filter: filter, reporter: reporter)
        self.scheduler = AutoRefreshScheduler(defaults: defaults)

        let widgetRegistry = viewRegistry
        let widgetFetcher = fetcher
        self.widgetSync = WidgetSync { [widgetRegistry, widgetFetcher] in
            Self.buildWidgetData(registry: widgetRegistry, fetcher: widgetFetcher)
        }

        for view in viewRegistry.views {
            fetcher.ensureState(for: view.id)
        }

        fetcher.onFetched = { [weak self] outcome in
            guard let self else { return }
            self.handleFetchOutcome(outcome)
            // During refreshAll, defer the widget write to a single sync at the
            // end instead of N churned cancels-and-reschedules.
            if !self.isRefreshingAll {
                self.widgetSync.sync()
            }
        }
    }

    deinit {
        pendingScheduledRefreshes.cancelAll()
        pendingSideEffectTasks.cancelAll()
        // All other collaborators (scheduler, fetcher, widgetSync) cancel
        // their own Tasks in their own deinits, which run when this VM's
        // stored properties are released.
    }

    // MARK: - Collapsed Sections Persistence

    private func persistCollapsedSections() {
        defaults.set(Array(collapsedOrgs), forKey: Constants.UserDefaultsKeys.collapsedOrgs)
        defaults.set(Array(collapsedRepos), forKey: Constants.UserDefaultsKeys.collapsedRepos)
    }

    // MARK: - Badge / Notification Forwarding

    var onBadgeCountChanged: ((Int) -> Void)? {
        get { badgeTracker.onCountChanged }
        set { badgeTracker.onCountChanged = newValue }
    }

    var badgeCount: Int { badgeTracker.count }

    func isBadgeEnabled(for viewID: UUID) -> Bool {
        badgeTracker.isEnabled(for: viewID)
    }

    func setBadge(for viewID: UUID, enabled: Bool) {
        badgeTracker.setEnabled(for: viewID, enabled: enabled, currentPRs: fetcher.state(for: viewID).pullRequests)
    }

    func markBadgeAsSeen() {
        badgeTracker.markAsSeen()
    }

    func markBadgeAsSeenForSelectedView() {
        guard let viewID = selectedViewID else { return }
        let prIDs = Set(fetcher.state(for: viewID).pullRequests.map(\.id))
        guard !prIDs.isEmpty else { return }
        badgeTracker.markAsSeen(prIDs: prIDs)
    }

    var systemNotificationsAuthorized: Bool { notificationService.systemAuthorized }

    func isNotificationEnabled(for viewID: UUID) -> Bool {
        notificationService.isEnabled(for: viewID)
    }

    func setNotification(for viewID: UUID, enabled: Bool) {
        notificationService.setEnabled(for: viewID, enabled: enabled)
    }

    func ensureNotificationPermission(for viewID: UUID) async {
        await notificationService.ensurePermission(for: viewID)
    }

    func refreshNotificationAuthorization() async {
        await notificationService.refreshAuthorization()
    }

    func requestNotificationPermissionAndOpenSettings() async {
        await notificationService.requestPermissionAndOpenSettings()
    }

    // MARK: - Grouping (memoized)

    typealias PRStack = PRGrouping.PRStack
    typealias OrgGroup = PRGrouping.OrgGroup
    typealias RepoGroup = PRGrouping.RepoGroup

    private struct GroupedCache {
        let viewID: UUID?
        let prs: [PullRequest]
        let groups: [OrgGroup]
    }

    /// Cache is excluded from Observation tracking — writes must not cascade
    /// into SwiftUI re-renders (the underlying `pullRequests` mutation
    /// already triggered the observation that led us to recompute).
    @ObservationIgnored private var groupedCache: GroupedCache?

    /// Test hook — counts how many times `groupedSelected` actually
    /// recomputed the grouping rather than returning a cached result.
    /// `@ObservationIgnored` so it doesn't participate in SwiftUI tracking.
    @ObservationIgnored private(set) var groupedRecomputeCount: UInt64 = 0

    /// Grouping of the currently selected view's pull requests. Cached
    /// against the backing `[PullRequest]` buffer so repeated reads during
    /// a single render cycle (loading-state flips, `onAppear`, TimelineView
    /// ticks, `.onChange` passes) return in O(1). Recomputes only when the
    /// selected view changes or its PR list is reassigned.
    var groupedSelected: [OrgGroup] {
        let viewID = selectedViewID
        let prs = selectedViewState.pullRequests
        if let cached = groupedCache, cached.viewID == viewID, cached.prs == prs {
            return cached.groups
        }
        let groups = PRGrouping.groupedByOrgAndRepo(prs)
        groupedCache = GroupedCache(viewID: viewID, prs: prs, groups: groups)
        groupedRecomputeCount &+= 1
        return groups
    }

    func groupedByOrgAndRepo(_ pullRequests: [PullRequest]) -> [OrgGroup] {
        PRGrouping.groupedByOrgAndRepo(pullRequests)
    }

    // MARK: - Refresh

    func refresh(viewID: UUID) async {
        guard let view = views.first(where: { $0.id == viewID }) else { return }
        await fetcher.refresh(for: view)
    }

    func loadMore(viewID: UUID) async {
        guard let view = views.first(where: { $0.id == viewID }) else { return }
        await fetcher.loadMore(for: view)
    }

    func refreshAll() async {
        let viewsSnapshot = views
        isRefreshingAll = true
        await withTaskGroup(of: Void.self) { group in
            for view in viewsSnapshot {
                group.addTask { [fetcher] in await fetcher.refresh(for: view) }
            }
        }
        isRefreshingAll = false
        guard !Task.isCancelled else { return }
        badgeTracker.pruneUnseen(viewStates: fetcher.states)
        widgetSync.sync()
    }

    // MARK: - Auto-Refresh

    func startAutoRefresh() {
        scheduler.start(tick: { [weak self] in
            guard let self else {
                return AutoRefreshTickResult(hasData: false, hasError: false, maxRateLimitWait: nil, hasViews: false)
            }
            await self.refreshAll()
            let states = self.fetcher.states.values
            return AutoRefreshTickResult(
                hasData: states.contains(where: \.hasData),
                hasError: states.contains(where: { $0.error != nil }),
                maxRateLimitWait: states.compactMap(\.rateLimitRetryAfter).max(),
                hasViews: !self.views.isEmpty
            )
        })
    }

    func stopAutoRefresh() {
        scheduler.stop()
        pendingScheduledRefreshes.cancelAll()
    }

    // MARK: - CRUD

    func addView(_ view: DashboardView) {
        viewRegistry.addView(view)
        fetcher.ensureState(for: view.id)
    }

    func updateView(_ view: DashboardView) {
        viewRegistry.updateView(view)
    }

    func toggleHideReviewed(for viewID: UUID) {
        guard let index = views.firstIndex(where: { $0.id == viewID }) else { return }
        var updated = views[index]
        updated.hideReviewed.toggle()
        viewRegistry.updateView(updated)
        scheduleRefresh(for: updated)
    }

    func moveView(from sourceID: UUID, to targetID: UUID) {
        viewRegistry.moveView(from: sourceID, to: targetID)
    }

    func selectNextView() {
        viewRegistry.selectNext()
        markBadgeAsSeenForSelectedView()
    }

    func selectPreviousView() {
        viewRegistry.selectPrevious()
        markBadgeAsSeenForSelectedView()
    }

    func deleteView(id: UUID) {
        viewRegistry.deleteView(id: id)
        fetcher.removeState(for: id)
        badgeTracker.removeView(id: id)
        notificationService.removeView(id: id)
        badgeTracker.pruneUnseen(viewStates: fetcher.states)
    }

    func presetConflicts() -> [String] {
        let existingTitles = Set(views.map(\.title))
        return DashboardView.presetViews
            .map(\.title)
            .filter { existingTitles.contains($0) }
    }

    func createPresetViews(replacingConflicts: Bool) {
        var viewsToRefresh: [DashboardView] = []
        for preset in DashboardView.presetViews {
            if let existingIndex = views.firstIndex(where: { $0.title == preset.title }) {
                if replacingConflicts {
                    let oldID = views[existingIndex].id
                    let replacement = DashboardView(
                        id: oldID,
                        title: preset.title,
                        query: preset.query,
                        hideReviewed: preset.hideReviewed
                    )
                    viewRegistry.updateView(replacement)
                    viewsToRefresh.append(replacement)
                }
            } else {
                let newView = DashboardView(
                    id: UUID(),
                    title: preset.title,
                    query: preset.query,
                    hideReviewed: preset.hideReviewed
                )
                viewRegistry.addView(newView)
                fetcher.ensureState(for: newView.id)
                viewsToRefresh.append(newView)
            }
        }
        for view in viewsToRefresh {
            scheduleRefresh(for: view)
        }
    }

    func reloadViews() {
        viewRegistry.reload()
        for view in viewRegistry.views {
            fetcher.ensureState(for: view.id)
        }
    }

    // MARK: - Sign Out

    func clearAllData() {
        stopAutoRefresh()
        localRepositoryService.stopPeriodicRefresh()
        viewRegistry.clear()
        fetcher.clearAll()
        let identity = self.identity
        let key = UUID()
        let tasks = pendingSideEffectTasks
        let task = Task {
            await identity.invalidate(reason: .userSignedOut)
            tasks.remove(key)
        }
        pendingSideEffectTasks.insert(task, for: key)
        badgeTracker.reset()
        notificationService.reset()
        collapsedOrgs = []
        collapsedRepos = []
        widgetSync.writeNow()
    }

    // MARK: - Open in Editor

    var isVSCodeAvailable: Bool { localRepositoryService.isVSCodeAvailable }
    var isITermAvailable: Bool { localRepositoryService.isITermAvailable }

    func localMatch(for pr: PullRequest) -> LocalRepoMatch? {
        localRepositoryService.findLocalDirectory(for: pr)
    }

    func openInBrowser(_ pr: PullRequest) {
        NSWorkspace.shared.open(pr.url)
    }

    func openInEditor(_ pr: PullRequest) {
        guard let match = localMatch(for: pr) else { return }
        localRepositoryService.openInVSCode(path: match.path)
    }

    func openInTerminal(_ pr: PullRequest) {
        guard let match = localMatch(for: pr) else { return }
        localRepositoryService.openInITerm(path: match.path)
    }

    // MARK: - Query Editing

    func commitQueryEdit(viewID: UUID, newQuery: String) {
        guard let dashView = views.first(where: { $0.id == viewID }) else { return }
        let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != dashView.query else { return }
        let updated = DashboardView(id: dashView.id, title: dashView.title, query: trimmed, hideReviewed: dashView.hideReviewed)
        viewRegistry.updateView(updated)
        fetcher.resetState(for: viewID)
        scheduleRefresh(for: updated)
    }

    func queryContainsFilter(qualifier: String) -> Bool {
        guard let viewID = selectedViewID,
              let dashView = views.first(where: { $0.id == viewID }) else { return false }
        return dashView.query.split(separator: " ").contains(where: { String($0) == qualifier })
    }

    func appendFilter(viewID: UUID, qualifier: String) {
        guard let dashView = views.first(where: { $0.id == viewID }) else { return }
        guard !dashView.query.split(separator: " ").contains(where: { String($0) == qualifier }) else { return }
        let newQuery = dashView.query + " " + qualifier
        let updated = DashboardView(id: dashView.id, title: dashView.title, query: newQuery, hideReviewed: dashView.hideReviewed)
        viewRegistry.updateView(updated)
        fetcher.resetState(for: viewID)
        scheduleRefresh(for: updated)
    }

    // MARK: - Private

    private func scheduleRefresh(for view: DashboardView) {
        pendingScheduledRefreshes.cancelAndRemove(view.id)
        let fetcher = self.fetcher
        let task = Task {
            await fetcher.refresh(for: view)
        }
        pendingScheduledRefreshes.insert(task, for: view.id)
    }

    private func handleFetchOutcome(_ outcome: PRFetcher.FetchOutcome) {
        let notifyEnabled = notificationService.isEnabled(for: outcome.viewID)
        let badgeEnabled = badgeTracker.isEnabled(for: outcome.viewID)
        guard notifyEnabled || badgeEnabled else { return }

        let addedIDs = badgeTracker.detectNewPRs(viewID: outcome.viewID, currentPRs: outcome.pullRequests)
        guard !addedIDs.isEmpty else { return }

        if badgeEnabled {
            badgeTracker.trackUnseen(addedIDs)
        }

        guard notifyEnabled else { return }
        guard let view = views.first(where: { $0.id == outcome.viewID }) else { return }
        let addedPRs = outcome.pullRequests.filter { addedIDs.contains($0.id) }
        let notificationService = self.notificationService
        let key = UUID()
        let tasks = pendingSideEffectTasks
        let task = Task {
            await notificationService.deliver(viewTitle: view.title, viewID: outcome.viewID, addedPRs: addedPRs)
            tasks.remove(key)
        }
        pendingSideEffectTasks.insert(task, for: key)
    }

    private static func buildWidgetData(registry: ViewRegistry, fetcher: PRFetcher) -> WidgetData {
        let widgetViews = registry.views.map { view in
            let prs = fetcher.state(for: view.id).pullRequests
            let widgetPRs = prs.prefix(10).map { pr in
                WidgetPullRequest(
                    id: pr.id,
                    number: pr.number,
                    title: pr.title,
                    url: pr.url,
                    repositoryName: pr.repository.nameWithOwner,
                    authorLogin: pr.author.login,
                    createdAt: pr.createdAt,
                    reviewDecision: pr.reviewDecision?.rawValue,
                    checkStatus: pr.checkStatus?.rawValue,
                    isDraft: pr.isDraft,
                    state: pr.state.rawValue
                )
            }
            let decisionCounts = prs.reduce(into: (approved: 0, changesRequested: 0)) { acc, pr in
                switch pr.reviewDecision {
                case .approved: acc.approved += 1
                case .changesRequested: acc.changesRequested += 1
                default: break
                }
            }
            return WidgetViewData(
                id: view.id.uuidString,
                title: view.title,
                count: prs.count,
                approvedCount: decisionCounts.approved,
                changesRequestedCount: decisionCounts.changesRequested,
                pullRequests: Array(widgetPRs)
            )
        }
        return WidgetData(views: widgetViews, lastUpdated: .now)
    }
}
