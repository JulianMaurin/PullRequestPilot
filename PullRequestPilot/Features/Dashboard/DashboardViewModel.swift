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
    /// `error` came from loading the next page, not from a refresh.
    var loadMoreFailed = false
    var nextCursor: String?
    var rateLimitRetryAfter: TimeInterval?
    var reachedLimit = false
    var rawFetchedCount = 0
    var nonPullRequestCount = 0
    /// Pull requests the view's filter removed (hide-reviewed).
    var filteredOutCount = 0
    /// Why GitHub matched results the list can't show (withheld behind SSO,
    /// undecodable); nil when nothing is hidden.
    var hiddenResultsNotice: String?
    /// When a refresh last succeeded; failed refreshes keep the old rows.
    var lastRefreshedAt: Date?

    var isEmpty: Bool { pullRequests.isEmpty && !isLoading }
    var hasData: Bool { !pullRequests.isEmpty }
    var canLoadMore: Bool { nextCursor != nil && !isLoadingMore && !reachedLimit }
    /// GitHub has more results than the app fetches.
    var isTruncated: Bool { reachedLimit && nextCursor != nil }
}

@MainActor
@Observable
final class DashboardViewModel {

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
    private let logger = Logger(category: "Dashboard")

    // MARK: - Init

    /// `notificationCenter` and `widgetDestination` are the system endpoints
    /// the dashboard writes to; tests pass doubles so no run touches the
    /// user's notifications or widgets.
    init(
        gitHubClient: GitHubClientProtocol,
        identity: IdentityActor,
        viewsStore: any ViewsStoreProtocol,
        localRepositoryService: LocalRepositoryService,
        defaults: UserDefaults,
        notificationCenter: any UserNotificationCenterProtocol,
        widgetDestination: WidgetDestination,
        reporter: EventReporter = .noop,
        availabilityEvents: AsyncStream<SystemAvailabilityEvent>? = nil
    ) {
        self.gitHubClient = gitHubClient
        self.identity = identity
        self.localRepositoryService = localRepositoryService
        self.defaults = defaults
        self.reporter = reporter
        self.collapsedOrgs = Set(defaults.stringArray(forKey: Constants.UserDefaultsKeys.collapsedOrgs) ?? [])
        self.collapsedRepos = Set(defaults.stringArray(forKey: Constants.UserDefaultsKeys.collapsedRepos) ?? [])
        self.badgeTracker = BadgeTracker(defaults: defaults)
        self.notificationService = NotificationService(defaults: defaults, center: notificationCenter, reporter: reporter)
        self.viewRegistry = ViewRegistry(viewsStore: viewsStore, defaults: defaults)

        let filterIdentity = identity
        let filterReporter = reporter
        let filterLogger = Logger(category: "Dashboard.Filter")
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
            filterReporter.resolve { $0 == .viewerIdentityUnavailable }
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
        self.scheduler = AutoRefreshScheduler(defaults: defaults, availabilityEvents: availabilityEvents)

        let widgetRegistry = viewRegistry
        let widgetFetcher = fetcher
        self.widgetSync = WidgetSync(destination: widgetDestination) { [widgetRegistry, widgetFetcher] in
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
        let wasTracking = isTrackingNewPRs(in: viewID)
        badgeTracker.setEnabled(for: viewID, enabled: enabled)
        updateNewPRBaseline(for: viewID, wasTracking: wasTracking)
        if !enabled {
            // Drop any unseen IDs that were tracked for this view and are not
            // still surfaced by another enabled view.
            badgeTracker.pruneUnseen(viewStates: fetcher.states)
        }
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
        let wasTracking = isTrackingNewPRs(in: viewID)
        notificationService.setEnabled(for: viewID, enabled: enabled)
        updateNewPRBaseline(for: viewID, wasTracking: wasTracking)
    }

    private func isTrackingNewPRs(in viewID: UUID) -> Bool {
        badgeTracker.isEnabled(for: viewID) || notificationService.isEnabled(for: viewID)
    }

    /// The badge and the bell share one new-PR baseline. It lives while either
    /// is on, and restarts from the rows on screen when the first of them turns
    /// on, so a muted stretch can't come back as a backlog.
    private func updateNewPRBaseline(for viewID: UUID, wasTracking: Bool) {
        let isTracking = isTrackingNewPRs(in: viewID)
        if isTracking && !wasTracking {
            badgeTracker.seedBaseline(for: viewID, currentPRs: fetcher.state(for: viewID).pullRequests)
        } else if !isTracking {
            badgeTracker.resetBaseline(for: viewID)
        }
    }

    /// The bell is on but notifications are off in System Settings.
    func isNotificationBlocked(for viewID: UUID) -> Bool {
        notificationService.isEnabled(for: viewID) && notificationService.systemDenied
    }

    func ensureNotificationPermission() async {
        await notificationService.ensurePermission()
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

    func addViewAndRefresh(_ view: DashboardView) {
        addView(view)
        scheduleRefresh(for: view)
    }

    func updateView(_ view: DashboardView) {
        let previous = views.first { $0.id == view.id }
        viewRegistry.updateView(view)
        if previous?.query != view.query || previous?.hideReviewed != view.hideReviewed {
            resetResults(for: view.id)
        }
    }

    /// A changed query or filter is a different result set: drop the old rows
    /// and cursor, and restart the new-PR baseline so the rows that appear
    /// aren't announced as new.
    private func resetResults(for viewID: UUID) {
        fetcher.resetState(for: viewID)
        badgeTracker.resetBaseline(for: viewID)
    }

    func toggleHideReviewed(for viewID: UUID) {
        guard let index = views.firstIndex(where: { $0.id == viewID }) else { return }
        var updated = views[index]
        updated.hideReviewed.toggle()
        viewRegistry.updateView(updated)
        // Clear the cached PR list so the user sees a loading state rather than
        // the stale pre-toggle list while the refresh is in flight. Mirrors
        // commitQueryEdit / appendFilter.
        resetResults(for: viewID)
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

    // MARK: - Presets

    /// Adds a copy of `preset` as a new view and loads it.
    func addPresetView(_ preset: DashboardView) {
        addViewAndRefresh(DashboardView(
            id: UUID(),
            title: preset.title,
            query: preset.query,
            hideReviewed: preset.hideReviewed
        ))
    }

    /// Restores the query and filter of the view named after `preset`. The
    /// view keeps its ID, so its bell and badge settings stay.
    func resetPresetView(_ preset: DashboardView) {
        guard let existing = views.first(where: { $0.title == preset.title }) else { return }
        let restored = DashboardView(
            id: existing.id,
            title: preset.title,
            query: preset.query,
            hideReviewed: preset.hideReviewed
        )
        updateView(restored)
        scheduleRefresh(for: restored)
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

    // MARK: - Opening

    func localMatch(for pr: PullRequest) -> LocalRepoMatch? {
        localRepositoryService.findLocalDirectory(for: pr)
    }

    func openInBrowser(_ pr: PullRequest) {
        NSWorkspace.shared.open(pr.url)
    }

    // MARK: - Draft State

    /// Refreshes every view afterwards: the change can move the PR into or out
    /// of views filtered on `draft:` or `is:draft`.
    func setDraft(_ pr: PullRequest, isDraft: Bool) async {
        do {
            try await gitHubClient.setDraft(pullRequestID: pr.id, isDraft: isDraft)
        } catch is CancellationError {
            return
        } catch GitHubClientError.graphQLErrors(let messages) {
            reporter.postError(.draftStateChangeFailed(
                pullRequestNumber: pr.number,
                isDraft: isDraft,
                detail: messages.joined(separator: "; ")
            ))
            return
        } catch {
            reporter.postError(error.asAppError)
            return
        }
        reporter.postInfo(isDraft ? "#\(pr.number) converted to draft." : "#\(pr.number) marked as ready for review.")
        await refreshAll()
    }

    // MARK: - Query Editing

    func commitQueryEdit(viewID: UUID, newQuery: String) {
        guard let dashView = views.first(where: { $0.id == viewID }) else { return }
        let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != dashView.query else { return }
        let updated = DashboardView(id: dashView.id, title: dashView.title, query: trimmed, hideReviewed: dashView.hideReviewed)
        viewRegistry.updateView(updated)
        resetResults(for: viewID)
        scheduleRefresh(for: updated)
    }

    func appendFilter(viewID: UUID, qualifier: SearchQualifier) {
        guard let dashView = views.first(where: { $0.id == viewID }) else { return }
        let query = SearchQuery(dashView.query)
        guard !query.contains(qualifier) else { return }
        let newQuery = query.appending(qualifier).text
        let updated = DashboardView(id: dashView.id, title: dashView.title, query: newQuery, hideReviewed: dashView.hideReviewed)
        viewRegistry.updateView(updated)
        resetResults(for: viewID)
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
                    reviewDecision: pr.reviewDecision,
                    checkStatus: pr.checkStatus,
                    isDraft: pr.isDraft,
                    state: pr.state
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
        // The widget's "Updated … ago" must not advance while fetches fail.
        let lastRefreshedAt = registry.views.compactMap { fetcher.state(for: $0.id).lastRefreshedAt }.max()
        return WidgetData(views: widgetViews, lastUpdated: lastRefreshedAt ?? .now)
    }
}
