import Foundation
import os
import SwiftUI

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
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "GitHubDashboard", category: "Dashboard")

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

        logger.info("Fetching PRs for '\(view.title)'...")

        do {
            let page = try await gitHubClient.fetchPullRequests(query: view.query, cursor: nil)
            let prs = page.pullRequests
            var seenIDs = Set<String>()
            let uniquePRs = prs.filter { seenIDs.insert($0.id).inserted }

            viewStates[viewID]?.pullRequests = uniquePRs
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

            viewStates[viewID]?.pullRequests.append(contentsOf: newPRs)
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
        await withTaskGroup(of: Void.self) { group in
            for view in views {
                group.addTask { await self.refresh(viewID: view.id) }
            }
        }
    }

    func startAutoRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll()
                try? await Task.sleep(for: .seconds(Constants.App.refreshInterval))
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
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

    func deleteView(id: UUID) {
        views.removeAll { $0.id == id }
        viewStates.removeValue(forKey: id)
        viewsStore.save(views)
        if selectedViewID == id {
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
