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
    var nextCursor: String?
    var reachedLimit = false

    var isEmpty: Bool { pullRequests.isEmpty && !isLoading }
    var canLoadMore: Bool { nextCursor != nil && !isLoadingMore && !reachedLimit }
}

@MainActor
@Observable
final class DashboardViewModel {
    private(set) var views: [DashboardView]
    private(set) var viewStates: [UUID: ViewState] = [:]
    var selectedViewID: UUID?

    private let gitHubClient: GitHubClientProtocol
    private let viewsStore: ViewsStore
    private let localRepositoryService: LocalRepositoryService
    private var refreshTask: Task<Void, Never>?
    private var previousPRIDs: [UUID: Set<String>] = [:]
    private var hasCompletedInitialLoad: Set<UUID> = []
    private var viewerLogin: String?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PullRequestPilot", category: "Dashboard")

    init(gitHubClient: GitHubClientProtocol, viewsStore: ViewsStore, localRepositoryService: LocalRepositoryService) {
        self.gitHubClient = gitHubClient
        self.viewsStore = viewsStore
        self.localRepositoryService = localRepositoryService
        self.views = viewsStore.load()
        self.selectedViewID = views.first?.id

        for view in views {
            viewStates[view.id] = ViewState()
        }
    }

    var selectedViewState: ViewState {
        guard let id = selectedViewID else { return ViewState() }
        return viewStates[id] ?? ViewState()
    }

    // MARK: - Refresh

    func refresh(viewID: UUID) async {
        guard let view = views.first(where: { $0.id == viewID }) else { return }

        viewStates[viewID] = ViewState(isLoading: true)

        if view.hideReviewed {
            await fetchViewerLoginIfNeeded()
        }

        logger.info("Fetching PRs for '\(view.title)'...")

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
            logger.info("Fetched \(uniquePRs.count) PR(s) for '\(view.title)'")
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            logger.error("Failed to fetch PRs for '\(view.title)': \(error)")
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
            logger.info("Loaded \(newPRs.count) more PR(s) for '\(view.title)' (total: \(totalCount))")
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            logger.error("Failed to load more PRs for '\(view.title)': \(error)")
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
            viewerLogin = try await gitHubClient.fetchViewerLogin()
        } catch {
            logger.warning("Failed to fetch viewer login: \(error)")
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
                    isDraft: pr.isDraft
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
                let interval = UserDefaults.standard.double(forKey: Constants.UserDefaultsKeys.prRefreshInterval)
                let seconds = interval > 0 ? interval : Constants.App.defaultPRRefreshInterval
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
        observeRefreshIntervalChanges()
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func restartAutoRefresh() {
        stopAutoRefresh()
        startAutoRefresh()
    }

    private func observeRefreshIntervalChanges() {
        NotificationCenter.default.addObserver(
            forName: Constants.Notifications.prRefreshIntervalChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.restartAutoRefresh()
            }
        }
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

    func deleteView(id: UUID) {
        views.removeAll { $0.id == id }
        viewStates.removeValue(forKey: id)
        viewsStore.save(views)
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
        if selectedViewID == nil || !currentIDs.contains(selectedViewID!) {
            selectedViewID = views.first?.id
        }
    }

    func openInBrowser(_ pr: PullRequest) {
        NSWorkspace.shared.open(pr.url)
    }

    // MARK: - Notifications

    var notifiedViewIDs: Set<String> {
        get {
            Set(UserDefaults.standard.stringArray(forKey: Constants.UserDefaultsKeys.notifiedViewIDs) ?? [])
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: Constants.UserDefaultsKeys.notifiedViewIDs)
        }
    }

    func isNotificationEnabled(for viewID: UUID) -> Bool {
        notifiedViewIDs.contains(viewID.uuidString)
    }

    func toggleNotification(for viewID: UUID) {
        var ids = notifiedViewIDs
        if ids.contains(viewID.uuidString) {
            ids.remove(viewID.uuidString)
        } else {
            ids.insert(viewID.uuidString)
            requestNotificationPermission()
        }
        notifiedViewIDs = ids
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                self.logger.error("Notification permission error: \(error)")
            }
        }
    }

    private func checkAndNotify(viewID: UUID, newPRs: [PullRequest]) {
        guard isNotificationEnabled(for: viewID) else { return }

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

        guard let view = views.first(where: { $0.id == viewID }) else { return }

        let count = addedIDs.count
        let content = UNMutableNotificationContent()
        content.title = view.title
        content.body = "\(count) new PR\(count == 1 ? "" : "s")"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "new-prs-\(viewID.uuidString)-\(Date.now.timeIntervalSince1970)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                self.logger.error("Failed to deliver notification: \(error)")
            }
        }
    }

    // MARK: - Open in Editor

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
