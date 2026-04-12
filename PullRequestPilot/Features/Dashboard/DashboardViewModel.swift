import Foundation
import os
import SwiftUI
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
    private var refreshIntervalObserver: (any NSObjectProtocol)?
    private var previousPRIDs: [UUID: Set<String>] = [:]
    private var hasCompletedInitialLoad: Set<UUID> = []
    private var viewerLogin: String?
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

        if viewStates[viewID] == nil {
            viewStates[viewID] = ViewState()
        }
        viewStates[viewID]?.isLoading = true
        viewStates[viewID]?.error = nil
        viewStates[viewID]?.isNetworkError = false

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

            checkAndNotify(viewID: viewID, newPRs: filteredPRs)
            viewStates[viewID]?.pullRequests = filteredPRs
            viewStates[viewID]?.seenIDs = seenIDs
            viewStates[viewID]?.nextCursor = page.nextCursor
            viewStates[viewID]?.reachedLimit = uniquePRs.count >= Constants.App.maxPullRequests
            logger.info("Fetched \(uniquePRs.count, privacy: .public) PR(s) for '\(view.title, privacy: .public)'")
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            logger.error("Failed to fetch PRs for '\(view.title, privacy: .public)': \(error, privacy: .public)")
            viewStates[viewID]?.isNetworkError = error.isNetworkError
            viewStates[viewID]?.error = error.localizedDescription
        }

        viewStates[viewID]?.isLoading = false
    }

    func loadMore(viewID: UUID) async {
        guard let view = views.first(where: { $0.id == viewID }),
              let state = viewStates[viewID],
              state.canLoadMore else { return }

        viewStates[viewID]?.isLoadingMore = true

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
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            logger.error("Failed to load more PRs for '\(view.title, privacy: .public)': \(error, privacy: .public)")
            viewStates[viewID]?.isNetworkError = error.isNetworkError
            viewStates[viewID]?.error = error.localizedDescription
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
        updateWidgetData()
    }

    private func fetchViewerLoginIfNeeded() async {
        guard viewerLogin == nil else { return }
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
                pullRequests: Array(widgetPRs)
            )
        }
        WidgetData(views: widgetViews, lastUpdated: .now).save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    func startAutoRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll()
                let hasAnyData = self?.viewStates.values.contains(where: \.hasData) ?? false
                let seconds: Double
                if hasAnyData {
                    let interval = UserDefaults.standard.double(forKey: Constants.UserDefaultsKeys.prRefreshInterval)
                    seconds = interval > 0 ? interval : Constants.App.defaultPRRefreshInterval
                } else {
                    seconds = 5
                }
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
        observeRefreshIntervalChanges()
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        if let observer = refreshIntervalObserver {
            NotificationCenter.default.removeObserver(observer)
            refreshIntervalObserver = nil
        }
    }

    private func restartAutoRefresh() {
        stopAutoRefresh()
        startAutoRefresh()
    }

    private func observeRefreshIntervalChanges() {
        refreshIntervalObserver = NotificationCenter.default.addObserver(
            forName: Constants.Notifications.prRefreshIntervalChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.restartAutoRefresh()
            }
        }
    }


    // MARK: - Sign Out

    func clearAllData() {
        stopAutoRefresh()
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
        withAnimation(.easeInOut(duration: 0.2)) {
            views.move(fromOffsets: IndexSet(integer: sourceIndex),
                       toOffset: targetIndex > sourceIndex ? targetIndex + 1 : targetIndex)
        }
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

    var badgeViewIDs: Set<String> = [] {
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
        }
        badgeViewIDs = ids
    }

    func markBadgeAsSeen() {
        guard !unseenBadgePRIDs.isEmpty else { return }
        unseenBadgePRIDs.removeAll()
        notifyBadgeCount()
    }

    private func notifyBadgeCount() {
        onBadgeCountChanged?(badgeCount)
    }

    // MARK: - Notifications

    var notifiedViewIDs: Set<String> = [] {
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

    private func checkAndNotify(viewID: UUID, newPRs: [PullRequest]) {
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

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                self?.logger.error("Failed to deliver notification: \(error, privacy: .public)")
            }
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
}
