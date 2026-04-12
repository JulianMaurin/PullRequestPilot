import AppKit
import Foundation
import os
import UserNotifications
import WidgetKit

struct ViewState {
    var pullRequests: [PullRequest] = []
    var seenIDs: Set<String> = []
    var isLoading = false
    var isLoadingMore = false
    var error: String?
    var isNetworkError = false
    var nextCursor: String?
    var rateLimitRetryAfter: TimeInterval?
    var reachedLimit = false

    var isEmpty: Bool { pullRequests.isEmpty && !isLoading }
    var hasData: Bool { !pullRequests.isEmpty }
    var canLoadMore: Bool { nextCursor != nil && !isLoadingMore && !reachedLimit }
}

@MainActor
@Observable
final class DashboardViewModel {
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

    var onBadgeCountChanged: ((Int) -> Void)?

    private let gitHubClient: GitHubClientProtocol
    private let viewsStore: ViewsStore
    private let localRepositoryService: LocalRepositoryService
    private let defaults: UserDefaults
    private var refreshTask: Task<Void, Never>?
    private var refreshIntervalTask: Task<Void, Never>?
    private var previousPRIDs: [UUID: Set<String>] = [:]
    private var hasCompletedInitialLoad: Set<UUID> = []
    private var refreshingViewIDs: Set<UUID> = []
    private var viewerLogin: String?
    private var isFetchingViewer = false
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PullRequestPilot", category: "Dashboard")

    init(gitHubClient: GitHubClientProtocol, viewsStore: ViewsStore, localRepositoryService: LocalRepositoryService, defaults: UserDefaults = .standard) {
        self.gitHubClient = gitHubClient
        self.viewsStore = viewsStore
        self.localRepositoryService = localRepositoryService
        self.defaults = defaults
        self.collapsedOrgs = Set(defaults.stringArray(forKey: Constants.UserDefaultsKeys.collapsedOrgs) ?? [])
        self.collapsedRepos = Set(defaults.stringArray(forKey: Constants.UserDefaultsKeys.collapsedRepos) ?? [])
        self.badgeViewIDs = Set(defaults.stringArray(forKey: Constants.UserDefaultsKeys.badgeViewIDs) ?? [])
        self.notifiedViewIDs = Set(defaults.stringArray(forKey: Constants.UserDefaultsKeys.notifiedViewIDs) ?? [])
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
            viewStates[viewID]?.reachedLimit = filteredPRs.count >= Constants.App.maxPullRequests
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
            let totalCount = viewStates[viewID]?.pullRequests.count ?? 0
            viewStates[viewID]?.reachedLimit = totalCount >= Constants.App.maxPullRequests
            logger.info("Loaded \(newPRs.count, privacy: .public) more PR(s) for '\(view.title, privacy: .public)' (total: \(totalCount, privacy: .public))")
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
        pruneUnseenBadgePRIDs()
        updateWidgetData()
    }

    private func fetchViewerLoginIfNeeded() async {
        guard viewerLogin == nil, !isFetchingViewer else { return }
        isFetchingViewer = true
        defer { isFetchingViewer = false }
        do {
            let viewer = try await gitHubClient.fetchViewer()
            viewerLogin = viewer.login
        } catch {
            logger.warning("Failed to fetch viewer login: \(error, privacy: .public)")
        }
    }

    private func filterReviewedPRs(_ prs: [PullRequest], for view: DashboardView) -> [PullRequest] {
        guard view.hideReviewed, let login = viewerLogin else { return prs }
        return prs.filter { pr in
            guard let viewerReview = pr.latestReviews.first(where: { $0.login == login }) else {
                return true
            }
            // Keep the PR if the viewer's review was dismissed (needs re-review)
            return viewerReview.state == .dismissed
        }
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

    func startAutoRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            var consecutiveEmptyFetches = 0
            while !Task.isCancelled {
                await self?.refreshAll()
                let hasAnyData = self?.viewStates.values.contains(where: \.hasData) ?? false
                let hasAnyError = self?.viewStates.values.contains(where: { $0.error != nil }) ?? false
                let seconds: Double
                if hasAnyData && !hasAnyError {
                    consecutiveEmptyFetches = 0
                    let interval = UserDefaults.standard.double(forKey: Constants.UserDefaultsKeys.prRefreshInterval)
                    seconds = interval > 0 ? interval : Constants.App.defaultPRRefreshInterval
                } else if hasAnyError {
                    let rateLimitWait = self?.viewStates.values.compactMap(\.rateLimitRetryAfter).max()
                    if let wait = rateLimitWait, wait > 60 {
                        seconds = min(wait, 3600) // Cap at 1 hour
                    } else {
                        // Exponential backoff on errors: 10s, 20s, 40s, capped at 60s
                        consecutiveEmptyFetches += 1
                        seconds = min(10 * pow(2.0, Double(consecutiveEmptyFetches - 1)), 60)
                    }
                } else if self?.views.isEmpty == true {
                    // No views configured — use normal interval, nothing to fetch
                    let interval = UserDefaults.standard.double(forKey: Constants.UserDefaultsKeys.prRefreshInterval)
                    seconds = interval > 0 ? interval : Constants.App.defaultPRRefreshInterval
                } else {
                    // No data yet, no errors — initial load, use moderate interval
                    seconds = 30
                }
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
        observeRefreshIntervalChanges()
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshIntervalTask?.cancel()
        refreshIntervalTask = nil
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

    // MARK: - Sign Out

    func clearAllData() {
        stopAutoRefresh()
        localRepositoryService.stopPeriodicRefresh()
        views = []
        viewStates = [:]
        selectedViewID = nil
        previousPRIDs = [:]
        hasCompletedInitialLoad = []
        viewerLogin = nil
        notifiedViewIDs = []
        badgeViewIDs = []
        unseenBadgePRIDs = []
        collapsedOrgs = []
        collapsedRepos = []
        defaults.removeObject(forKey: Constants.UserDefaultsKeys.selectedViewID)
        viewsStore.save([])
        WidgetData(views: [], lastUpdated: .now).save()
        WidgetCenter.shared.reloadAllTimelines()
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
        Task { await refresh(viewID: viewID) }
    }

    func moveView(from sourceID: UUID, to targetID: UUID) {
        guard let sourceIndex = views.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = views.firstIndex(where: { $0.id == targetID }),
              sourceIndex != targetIndex else { return }
        views.move(fromOffsets: IndexSet(integer: sourceIndex),
                   toOffset: targetIndex > sourceIndex ? targetIndex + 1 : targetIndex)
        viewsStore.save(views)
    }

    // MARK: - View Navigation

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
        badgeViewIDs.remove(id.uuidString)
        notifiedViewIDs.remove(id.uuidString)
        if selectedViewID == id {
            selectedViewID = views.first?.id
        }
    }

    /// Returns the titles of preset views that conflict with existing views.
    func presetConflicts() -> [String] {
        let existingTitles = Set(views.map(\.title))
        return DashboardView.presetViews
            .map(\.title)
            .filter { existingTitles.contains($0) }
    }

    /// Creates preset views. If `replacingConflicts` is true, existing views whose title
    /// matches a preset are replaced. Otherwise conflicting presets are skipped.
    func createPresetViews(replacingConflicts: Bool) {
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
            }
        }
        viewsStore.save(views)
        if selectedViewID == nil {
            selectedViewID = views.first?.id
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

    func openInBrowser(_ pr: PullRequest) {
        NSWorkspace.shared.open(pr.url)
    }

    // MARK: - Badge Count

    private(set) var badgeViewIDs: Set<String> = [] {
        didSet {
            defaults.set(Array(badgeViewIDs), forKey: Constants.UserDefaultsKeys.badgeViewIDs)
            notifyBadgeCount()
        }
    }

    private(set) var unseenBadgePRIDs: Set<String> = []

    var badgeCount: Int { unseenBadgePRIDs.count }

    func isBadgeEnabled(for viewID: UUID) -> Bool {
        badgeViewIDs.contains(viewID.uuidString)
    }

    func setBadge(for viewID: UUID, enabled: Bool) {
        var ids = badgeViewIDs
        if enabled {
            ids.insert(viewID.uuidString)
            // Set baseline from existing PRs so they aren't counted as "new"
            if previousPRIDs[viewID] == nil,
               let prs = viewStates[viewID]?.pullRequests, !prs.isEmpty {
                previousPRIDs[viewID] = Set(prs.map(\.id))
                hasCompletedInitialLoad.insert(viewID)
            }
        } else {
            ids.remove(viewID.uuidString)
            previousPRIDs.removeValue(forKey: viewID)
            hasCompletedInitialLoad.remove(viewID)
        }
        badgeViewIDs = ids
    }

    func markBadgeAsSeen() {
        guard !unseenBadgePRIDs.isEmpty else { return }
        unseenBadgePRIDs.removeAll()
        notifyBadgeCount()
    }

    /// Remove IDs from `unseenBadgePRIDs` that no longer appear in any badge-enabled view.
    private func pruneUnseenBadgePRIDs() {
        guard !unseenBadgePRIDs.isEmpty else { return }
        var allCurrentIDs = Set<String>()
        for viewIDString in badgeViewIDs {
            guard let uuid = UUID(uuidString: viewIDString) else { continue }
            let prs = viewStates[uuid]?.pullRequests ?? []
            allCurrentIDs.formUnion(prs.map(\.id))
        }
        let pruned = unseenBadgePRIDs.intersection(allCurrentIDs)
        if pruned.count != unseenBadgePRIDs.count {
            unseenBadgePRIDs = pruned
            notifyBadgeCount()
        }
    }

    private func notifyBadgeCount() {
        onBadgeCountChanged?(badgeCount)
    }

    // MARK: - Notifications

    private(set) var notifiedViewIDs: Set<String> = [] {
        didSet {
            defaults.set(Array(notifiedViewIDs), forKey: Constants.UserDefaultsKeys.notifiedViewIDs)
        }
    }

    private(set) var systemNotificationsAuthorized = false

    func isNotificationEnabled(for viewID: UUID) -> Bool {
        notifiedViewIDs.contains(viewID.uuidString)
    }

    func refreshNotificationAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        systemNotificationsAuthorized = settings.authorizationStatus == .authorized
        if !systemNotificationsAuthorized {
            // Disable all view toggles when system permission is revoked
            notifiedViewIDs = []
        }
    }

    func setNotification(for viewID: UUID, enabled: Bool) {
        var ids = notifiedViewIDs
        if enabled {
            ids.insert(viewID.uuidString)
        } else {
            ids.remove(viewID.uuidString)
        }
        notifiedViewIDs = ids
    }

    func ensureNotificationPermission(for viewID: UUID) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()

        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = await requestNotificationPermission()
            systemNotificationsAuthorized = granted
            if !granted {
                setNotification(for: viewID, enabled: false)
            }
        case .denied:
            systemNotificationsAuthorized = false
            setNotification(for: viewID, enabled: false)
        case .authorized, .provisional, .ephemeral:
            systemNotificationsAuthorized = true
        @unknown default:
            break
        }
    }

    func requestNotificationPermissionAndOpenSettings() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            let granted = await requestNotificationPermission()
            systemNotificationsAuthorized = granted
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings") {
            NSWorkspace.shared.open(url)
        }
    }

    private func requestNotificationPermission() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            logger.error("Notification permission error: \(error, privacy: .public)")
            return false
        }
    }

    private func checkAndNotify(viewID: UUID, newPRs: [PullRequest]) async {
        let notifyEnabled = isNotificationEnabled(for: viewID)
        let badgeEnabled = isBadgeEnabled(for: viewID)
        guard notifyEnabled || badgeEnabled else { return }

        let newIDs = Set(newPRs.map(\.id))

        guard hasCompletedInitialLoad.contains(viewID) else {
            previousPRIDs[viewID] = newIDs
            hasCompletedInitialLoad.insert(viewID)
            return
        }

        let previousIDs = previousPRIDs[viewID] ?? []
        let addedIDs = newIDs.subtracting(previousIDs)
        previousPRIDs[viewID] = newIDs

        guard !addedIDs.isEmpty else { return }

        // Track unseen PRs for badge count
        if badgeEnabled {
            unseenBadgePRIDs.formUnion(addedIDs)
            notifyBadgeCount()
        }

        guard notifyEnabled else { return }

        // Skip delivering notifications during unit tests
        guard NSClassFromString("XCTestCase") == nil else { return }

        guard let view = views.first(where: { $0.id == viewID }) else { return }

        let addedPRs = newPRs.filter { addedIDs.contains($0.id) }
        let content = UNMutableNotificationContent()
        content.title = view.title
        content.sound = .default

        if addedPRs.count == 1, let pr = addedPRs.first {
            content.subtitle = pr.repository.nameWithOwner
            content.body = "#\(pr.number) \(pr.title)"
        } else {
            let lines = addedPRs.prefix(4).map { "\($0.repository.nameWithOwner) #\($0.number) \($0.title)" }
            let remaining = addedPRs.count - lines.count
            let body = remaining > 0
                ? lines.joined(separator: "\n") + "\n+\(remaining) more"
                : lines.joined(separator: "\n")
            content.body = body
        }

        let request = UNNotificationRequest(
            identifier: "new-prs-\(viewID.uuidString)-\(Date.now.timeIntervalSince1970)",
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            logger.error("Failed to deliver notification: \(error, privacy: .public)")
        }
    }

    // MARK: - Open in Editor

    var isVSCodeAvailable: Bool { localRepositoryService.isVSCodeAvailable }
    var isITermAvailable: Bool { localRepositoryService.isITermAvailable }

    func localMatch(for pr: PullRequest) -> LocalRepoMatch? {
        localRepositoryService.findLocalDirectory(for: pr)
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
        Task { await refresh(viewID: viewID) }
    }

    func appendFilter(viewID: UUID, qualifier: String) {
        guard let dashView = views.first(where: { $0.id == viewID }) else { return }
        guard !dashView.query.contains(qualifier) else { return }
        let newQuery = dashView.query + " " + qualifier
        updateView(DashboardView(id: dashView.id, title: dashView.title, query: newQuery, hideReviewed: dashView.hideReviewed))
        viewStates[viewID] = ViewState()
        Task { await refresh(viewID: viewID) }
    }

    // MARK: - Grouping & Stacking

    struct PRStack: Identifiable {
        let root: PullRequest
        let children: [PullRequest]
        var id: String { root.id }
        var totalCount: Int { 1 + children.count }
    }

    struct OrgGroup {
        let org: String
        let repos: [RepoGroup]
    }

    struct RepoGroup {
        let repo: String
        let stacks: [PRStack]
    }

    func groupedByOrgAndRepo(_ pullRequests: [PullRequest]) -> [OrgGroup] {
        let byOrg = Dictionary(grouping: pullRequests) { $0.repository.owner }
        return byOrg.keys.sorted().compactMap { org in
            guard let orgPRs = byOrg[org] else { return nil }
            let byRepo = Dictionary(grouping: orgPRs) { $0.repository.name }
            let repoGroups = byRepo.keys.sorted().compactMap { repo -> RepoGroup? in
                guard let repoPRs = byRepo[repo] else { return nil }
                return RepoGroup(repo: repo, stacks: buildStacks(repoPRs))
            }
            return OrgGroup(org: org, repos: repoGroups)
        }
    }

    private func buildStacks(_ pullRequests: [PullRequest]) -> [PRStack] {
        let headToPR = Dictionary(pullRequests.map { ($0.headRefName, $0) }, uniquingKeysWith: { first, _ in first })
        let childIDs = Set(pullRequests.compactMap { pr -> String? in
            guard headToPR[pr.baseRefName] != nil else { return nil }
            return pr.id
        })
        let roots = pullRequests.filter { !childIDs.contains($0.id) }

        return roots.map { root in
            var children: [PullRequest] = []
            var currentHead = root.headRefName
            var visited: Set<String> = [root.id]
            while let next = pullRequests.first(where: { $0.baseRefName == currentHead && !visited.contains($0.id) }) {
                children.append(next)
                visited.insert(next.id)
                currentHead = next.headRefName
            }
            return PRStack(root: root, children: children)
        }
    }
}
