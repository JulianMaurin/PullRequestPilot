import AppKit
import Foundation
import os
import WidgetKit

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

    // MARK: - Properties

    private(set) var views: [DashboardView]
    private(set) var viewStates: [UUID: ViewState] = [:]
    var selectedViewID: UUID? {
        didSet { persistSelectedViewID() }
    }
    var showingSettings = false
    var collapsedOrgs: Set<String> {
        didSet { persistCollapsedSections() }
    }
    var collapsedRepos: Set<String> {
        didSet { persistCollapsedSections() }
    }

    let badgeTracker: BadgeTracker
    let notificationService: NotificationService

    private let gitHubClient: GitHubClientProtocol
    private let viewsStore: any ViewsStoreProtocol
    private let localRepositoryService: LocalRepositoryService
    private let defaults: UserDefaults
    private var refreshTask: Task<Void, Never>?
    private var refreshIntervalTask: Task<Void, Never>?
    private var hideReviewedTask: Task<Void, Never>?
    private var pendingRefreshTasks: [UUID: Task<Void, Never>] = [:]
    private var refreshingViewIDs: Set<UUID> = []
    private var viewerLogin: String?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PullRequestPilot", category: "Dashboard")

    // MARK: - Init

    init(gitHubClient: GitHubClientProtocol, viewsStore: any ViewsStoreProtocol, localRepositoryService: LocalRepositoryService, defaults: UserDefaults = .standard) {
        self.gitHubClient = gitHubClient
        self.viewsStore = viewsStore
        self.localRepositoryService = localRepositoryService
        self.defaults = defaults
        self.collapsedOrgs = Set(defaults.stringArray(forKey: Constants.UserDefaultsKeys.collapsedOrgs) ?? [])
        self.collapsedRepos = Set(defaults.stringArray(forKey: Constants.UserDefaultsKeys.collapsedRepos) ?? [])
        self.badgeTracker = BadgeTracker(defaults: defaults)
        self.notificationService = NotificationService(defaults: defaults)
        let loadedViews = viewsStore.load()
        self.views = loadedViews
        self.selectedViewID = Self.restoreSelectedViewID(from: defaults, views: loadedViews)

        for view in views {
            viewStates[view.id] = ViewState()
        }
    }

    private static func restoreSelectedViewID(from defaults: UserDefaults, views: [DashboardView]) -> UUID? {
        guard let stored = defaults.string(forKey: Constants.UserDefaultsKeys.selectedViewID),
              let uuid = UUID(uuidString: stored),
              views.contains(where: { $0.id == uuid }) else {
            return views.first?.id
        }
        return uuid
    }

    private func persistSelectedViewID() {
        defaults.set(selectedViewID?.uuidString, forKey: Constants.UserDefaultsKeys.selectedViewID)
    }

    private func persistCollapsedSections() {
        defaults.set(Array(collapsedOrgs), forKey: Constants.UserDefaultsKeys.collapsedOrgs)
        defaults.set(Array(collapsedRepos), forKey: Constants.UserDefaultsKeys.collapsedRepos)
    }

    var selectedViewState: ViewState {
        guard let id = selectedViewID else { return ViewState() }
        return viewStates[id] ?? ViewState()
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
        badgeTracker.setEnabled(for: viewID, enabled: enabled, currentPRs: viewStates[viewID]?.pullRequests ?? [])
    }

    func markBadgeAsSeen() {
        badgeTracker.markAsSeen()
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

    // MARK: - Grouping Forwarding

    typealias PRStack = PRGrouping.PRStack
    typealias OrgGroup = PRGrouping.OrgGroup
    typealias RepoGroup = PRGrouping.RepoGroup

    func groupedByOrgAndRepo(_ pullRequests: [PullRequest]) -> [OrgGroup] {
        PRGrouping.groupedByOrgAndRepo(pullRequests)
    }

    // MARK: - Refresh

    func refresh(viewID: UUID) async {
        guard let view = views.first(where: { $0.id == viewID }) else { return }
        guard refreshingViewIDs.insert(viewID).inserted else { return }
        defer { refreshingViewIDs.remove(viewID) }

        if viewStates[viewID] == nil {
            viewStates[viewID] = ViewState()
        }
        viewStates[viewID]?.isLoading = true
        viewStates[viewID]?.error = nil
        viewStates[viewID]?.isNetworkError = false
        viewStates[viewID]?.rateLimitRetryAfter = nil

        if view.hideReviewed {
            await fetchViewerLoginIfNeeded()
        }

        logger.info("Fetching PRs for '\(view.title, privacy: .public)'...")

        do {
            let page = try await gitHubClient.fetchPullRequests(query: view.query, cursor: nil)
            let prs = page.pullRequests
            var seenIDs = Set<String>()
            let uniquePRs = prs.filter { seenIDs.insert($0.id).inserted }
            let filteredPRs = filterReviewedPRs(uniquePRs, for: view)

            await checkAndNotify(viewID: viewID, newPRs: filteredPRs)
            viewStates[viewID]?.pullRequests = filteredPRs
            viewStates[viewID]?.seenIDs = seenIDs
            viewStates[viewID]?.nextCursor = page.nextCursor
            viewStates[viewID]?.rawFetchedCount = uniquePRs.count
            viewStates[viewID]?.reachedLimit = uniquePRs.count >= Constants.App.maxPullRequests
            viewStates[viewID]?.skippedPRCount = page.skippedNodeCount
            logger.info("Fetched \(uniquePRs.count, privacy: .public) PR(s) for '\(view.title, privacy: .public)'")
        } catch is CancellationError {
            viewStates[viewID]?.isLoading = false
            return
        } catch {
            logger.error("Failed to fetch PRs for '\(view.title, privacy: .public)': \(error, privacy: .public)")
            viewStates[viewID]?.isNetworkError = error.isNetworkError
            viewStates[viewID]?.error = error.localizedDescription
            if let clientError = error as? GitHubClientError, case .rateLimited(let retryAfter) = clientError {
                viewStates[viewID]?.rateLimitRetryAfter = retryAfter
            }
        }

        viewStates[viewID]?.isLoading = false
        updateWidgetData()
    }

    func loadMore(viewID: UUID) async {
        guard let view = views.first(where: { $0.id == viewID }),
              let state = viewStates[viewID],
              state.canLoadMore else { return }

        viewStates[viewID]?.isLoadingMore = true
        viewStates[viewID]?.error = nil
        viewStates[viewID]?.isNetworkError = false
        viewStates[viewID]?.rateLimitRetryAfter = nil

        do {
            let page = try await gitHubClient.fetchPullRequests(query: view.query, cursor: state.nextCursor)
            let newPRs = page.pullRequests.filter { viewStates[viewID]?.seenIDs.insert($0.id).inserted == true }
            let filteredNewPRs = filterReviewedPRs(newPRs, for: view)

            viewStates[viewID]?.pullRequests.append(contentsOf: filteredNewPRs)
            viewStates[viewID]?.nextCursor = page.nextCursor
            let rawTotal = (viewStates[viewID]?.rawFetchedCount ?? 0) + newPRs.count
            viewStates[viewID]?.rawFetchedCount = rawTotal
            viewStates[viewID]?.reachedLimit = rawTotal >= Constants.App.maxPullRequests
            logger.info("Loaded \(newPRs.count, privacy: .public) more PR(s) for '\(view.title, privacy: .public)' (total: \(rawTotal, privacy: .public))")
        } catch is CancellationError {
            viewStates[viewID]?.isLoadingMore = false
            return
        } catch {
            logger.error("Failed to load more PRs for '\(view.title, privacy: .public)': \(error, privacy: .public)")
            viewStates[viewID]?.isNetworkError = error.isNetworkError
            viewStates[viewID]?.error = error.localizedDescription
            if let clientError = error as? GitHubClientError, case .rateLimited(let retryAfter) = clientError {
                viewStates[viewID]?.rateLimitRetryAfter = retryAfter
            }
        }

        viewStates[viewID]?.isLoadingMore = false
    }

    func refreshAll() async {
        await fetchViewerLoginIfNeeded()
        await withTaskGroup(of: Void.self) { group in
            for view in views {
                group.addTask { await self.refresh(viewID: view.id) }
            }
        }
        guard !Task.isCancelled else { return }
        badgeTracker.pruneUnseen(viewStates: viewStates)
        updateWidgetData()
    }

    /// Clears the cached viewer login so the next refresh re-fetches it from the API.
    func resetViewerLogin() {
        viewerLogin = nil
        viewerLoginFetchFailed = false
        viewerLoginTask?.cancel()
        viewerLoginTask = nil
    }

    // MARK: - Auto-Refresh

    func startAutoRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            var consecutiveEmptyFetches = 0
            while !Task.isCancelled {
                await self?.refreshAll()
                let hasAnyData = self?.viewStates.values.contains(where: \.hasData) ?? false
                let hasAnyError = self?.viewStates.values.contains(where: { $0.error != nil }) ?? false
                let seconds: Double
                if hasAnyData {
                    consecutiveEmptyFetches = 0
                    let interval = self?.defaults.double(forKey: Constants.UserDefaultsKeys.prRefreshInterval) ?? 0
                    seconds = interval > 0 ? interval : Constants.App.defaultPRRefreshInterval
                } else if hasAnyError {
                    let rateLimitWait = self?.viewStates.values.compactMap(\.rateLimitRetryAfter).max()
                    if let wait = rateLimitWait, wait > 0 {
                        seconds = min(max(wait, 10), 3600)
                    } else {
                        consecutiveEmptyFetches += 1
                        seconds = min(10 * pow(2.0, Double(consecutiveEmptyFetches - 1)), 60)
                    }
                } else if self?.views.isEmpty == true {
                    let interval = self?.defaults.double(forKey: Constants.UserDefaultsKeys.prRefreshInterval) ?? 0
                    seconds = interval > 0 ? interval : Constants.App.defaultPRRefreshInterval
                } else {
                    seconds = 30
                }
                do {
                    try await Task.sleep(for: .seconds(seconds))
                } catch {
                    break
                }
            }
        }
        observeRefreshIntervalChanges()
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshIntervalTask?.cancel()
        refreshIntervalTask = nil
        hideReviewedTask?.cancel()
        hideReviewedTask = nil
        for task in pendingRefreshTasks.values {
            task.cancel()
        }
        pendingRefreshTasks.removeAll()
    }

    // MARK: - CRUD

    func addView(_ view: DashboardView) {
        views.append(view)
        viewStates[view.id] = ViewState()
        viewsStore.save(views)
        if selectedViewID == nil {
            selectedViewID = view.id
        }
    }

    func updateView(_ view: DashboardView) {
        guard let index = views.firstIndex(where: { $0.id == view.id }) else { return }
        views[index] = view
        viewsStore.save(views)
    }

    func toggleHideReviewed(for viewID: UUID) {
        guard let index = views.firstIndex(where: { $0.id == viewID }) else { return }
        views[index].hideReviewed.toggle()
        viewsStore.save(views)
        hideReviewedTask?.cancel()
        hideReviewedTask = Task { await refresh(viewID: viewID) }
    }

    func moveView(from sourceID: UUID, to targetID: UUID) {
        guard let sourceIndex = views.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = views.firstIndex(where: { $0.id == targetID }),
              sourceIndex != targetIndex else { return }
        views.move(fromOffsets: IndexSet(integer: sourceIndex),
                   toOffset: targetIndex > sourceIndex ? targetIndex + 1 : targetIndex)
        viewsStore.save(views)
    }

    func selectNextView() {
        guard let currentID = selectedViewID,
              let currentIndex = views.firstIndex(where: { $0.id == currentID }),
              !views.isEmpty else { return }
        let nextIndex = (currentIndex + 1) % views.count
        selectedViewID = views[nextIndex].id
    }

    func selectPreviousView() {
        guard let currentID = selectedViewID,
              let currentIndex = views.firstIndex(where: { $0.id == currentID }),
              !views.isEmpty else { return }
        let previousIndex = (currentIndex - 1 + views.count) % views.count
        selectedViewID = views[previousIndex].id
    }

    func deleteView(id: UUID) {
        views.removeAll { $0.id == id }
        viewStates.removeValue(forKey: id)
        viewsStore.save(views)
        badgeTracker.removeView(id: id)
        notificationService.removeView(id: id)
        badgeTracker.pruneUnseen(viewStates: viewStates)
        if selectedViewID == id {
            selectedViewID = views.first?.id
        }
    }

    func presetConflicts() -> [String] {
        let existingTitles = Set(views.map(\.title))
        return DashboardView.presetViews
            .map(\.title)
            .filter { existingTitles.contains($0) }
    }

    func createPresetViews(replacingConflicts: Bool) {
        var viewsToRefresh: [UUID] = []
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
                    views[existingIndex] = replacement
                    viewsToRefresh.append(oldID)
                }
            } else {
                let newView = DashboardView(
                    id: UUID(),
                    title: preset.title,
                    query: preset.query,
                    hideReviewed: preset.hideReviewed
                )
                views.append(newView)
                viewStates[newView.id] = ViewState()
                viewsToRefresh.append(newView.id)
            }
        }
        viewsStore.save(views)
        if selectedViewID == nil {
            selectedViewID = views.first?.id
        }
        for viewID in viewsToRefresh {
            scheduleRefresh(viewID: viewID)
        }
    }

    func reloadViews() {
        views = viewsStore.load()
        let currentIDs = Set(views.map(\.id))
        for key in viewStates.keys where !currentIDs.contains(key) {
            viewStates.removeValue(forKey: key)
        }
        for view in views where viewStates[view.id] == nil {
            viewStates[view.id] = ViewState()
        }
        if let selected = selectedViewID, currentIDs.contains(selected) {
            // keep current selection
        } else {
            selectedViewID = views.first?.id
        }
    }

    // MARK: - Sign Out

    func clearAllData() {
        stopAutoRefresh()
        localRepositoryService.stopPeriodicRefresh()
        views = []
        viewStates = [:]
        selectedViewID = nil
        viewerLogin = nil
        viewerLoginFetchFailed = false
        badgeTracker.reset()
        notificationService.reset()
        collapsedOrgs = []
        collapsedRepos = []
        defaults.removeObject(forKey: Constants.UserDefaultsKeys.selectedViewID)
        viewsStore.save([])
        WidgetData(views: [], lastUpdated: .now).save()
        WidgetCenter.shared.reloadAllTimelines()
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
        updateView(DashboardView(id: dashView.id, title: dashView.title, query: trimmed, hideReviewed: dashView.hideReviewed))
        viewStates[viewID] = ViewState()
        scheduleRefresh(viewID: viewID)
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
        updateView(DashboardView(id: dashView.id, title: dashView.title, query: newQuery, hideReviewed: dashView.hideReviewed))
        viewStates[viewID] = ViewState()
        scheduleRefresh(viewID: viewID)
    }

    // MARK: - Private

    private var viewerLoginTask: Task<Void, Never>?
    private var viewerLoginFetchFailed = false

    private func scheduleRefresh(viewID: UUID) {
        pendingRefreshTasks[viewID]?.cancel()
        pendingRefreshTasks[viewID] = Task {
            await refresh(viewID: viewID)
            pendingRefreshTasks.removeValue(forKey: viewID)
        }
    }

    private func fetchViewerLoginIfNeeded() async {
        if let existing = viewerLoginTask {
            await existing.value
            return
        }
        guard viewerLogin == nil, !viewerLoginFetchFailed else { return }
        let task = Task {
            do {
                let viewer = try await gitHubClient.fetchViewer()
                viewerLogin = viewer.login
            } catch {
                viewerLoginFetchFailed = true
                logger.warning("Failed to fetch viewer login: \(error, privacy: .public)")
            }
        }
        viewerLoginTask = task
        await task.value
        viewerLoginTask = nil
    }

    private func filterReviewedPRs(_ prs: [PullRequest], for view: DashboardView) -> [PullRequest] {
        guard view.hideReviewed, let login = viewerLogin else { return prs }
        return prs.filter { pr in
            guard let viewerReview = pr.latestReviews.first(where: { $0.login == login }) else {
                return true
            }
            return viewerReview.state == .dismissed
        }
    }

    private func checkAndNotify(viewID: UUID, newPRs: [PullRequest]) async {
        let notifyEnabled = notificationService.isEnabled(for: viewID)
        let badgeEnabled = badgeTracker.isEnabled(for: viewID)
        guard notifyEnabled || badgeEnabled else { return }

        let addedIDs = badgeTracker.detectNewPRs(viewID: viewID, currentPRs: newPRs)
        guard !addedIDs.isEmpty else { return }

        if badgeEnabled {
            badgeTracker.trackUnseen(addedIDs)
        }

        guard notifyEnabled else { return }
        guard let view = views.first(where: { $0.id == viewID }) else { return }
        let addedPRs = newPRs.filter { addedIDs.contains($0.id) }
        await notificationService.deliver(viewTitle: view.title, viewID: viewID, addedPRs: addedPRs)
    }

    private func updateWidgetData() {
        let widgetViews = views.map { view in
            let prs = viewStates[view.id]?.pullRequests ?? []
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
            return WidgetViewData(
                id: view.id.uuidString,
                title: view.title,
                count: prs.count,
                approvedCount: prs.filter { $0.reviewDecision == .approved }.count,
                changesRequestedCount: prs.filter { $0.reviewDecision == .changesRequested }.count,
                pullRequests: Array(widgetPRs)
            )
        }
        WidgetData(views: widgetViews, lastUpdated: .now).save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func restartAutoRefresh() {
        stopAutoRefresh()
        startAutoRefresh()
    }

    private func observeRefreshIntervalChanges() {
        refreshIntervalTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: Constants.Notifications.prRefreshIntervalChanged) {
                self?.restartAutoRefresh()
            }
        }
    }
}
