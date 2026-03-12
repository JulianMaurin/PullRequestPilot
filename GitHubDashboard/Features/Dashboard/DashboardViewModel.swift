import Foundation
import os
import SwiftUI

struct ViewState {
    var pullRequests: [PullRequest] = []
    var isLoading = false
    var error: String?

    var isEmpty: Bool { pullRequests.isEmpty && !isLoading }
}

@MainActor
@Observable
final class DashboardViewModel {
    private(set) var views: [DashboardView]
    private(set) var viewStates: [UUID: ViewState] = [:]
    var selectedViewID: UUID?

    private let gitHubClient: GitHubClientProtocol
    private let viewsStore: ViewsStore
    private var refreshTask: Task<Void, Never>?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "GitHubDashboard", category: "Dashboard")

    init(gitHubClient: GitHubClientProtocol, viewsStore: ViewsStore) {
        self.gitHubClient = gitHubClient
        self.viewsStore = viewsStore
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

        var state = viewStates[viewID] ?? ViewState()
        state.isLoading = state.pullRequests.isEmpty
        state.error = nil
        viewStates[viewID] = state

        logger.info("Fetching PRs for '\(view.title)'...")

        do {
            let prs = try await gitHubClient.fetchPullRequests(query: view.query)
            viewStates[viewID]?.pullRequests = prs
            logger.info("Fetched \(prs.count) PR(s) for '\(view.title)'")
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
        // Clean up stale states and init new ones
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
}
