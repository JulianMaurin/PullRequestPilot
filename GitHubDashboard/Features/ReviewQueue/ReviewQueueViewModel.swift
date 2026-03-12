import Foundation
import SwiftUI

@Observable
final class ReviewQueueViewModel {
    private(set) var pullRequests: [PullRequest] = []
    private(set) var isLoading = false
    private(set) var error: String?

    private let gitHubClient: GitHubClientProtocol
    private var refreshTask: Task<Void, Never>?

    init(gitHubClient: GitHubClientProtocol) {
        self.gitHubClient = gitHubClient
    }

    var isEmpty: Bool { pullRequests.isEmpty && !isLoading }

    func startAutoRefresh() {
        stopAutoRefresh()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(Constants.App.refreshInterval))
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    @MainActor
    func refresh() async {
        isLoading = pullRequests.isEmpty // Only show spinner on first load
        error = nil

        do {
            pullRequests = try await gitHubClient.fetchReviewRequests()
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    func openInBrowser(_ pr: PullRequest) {
        NSWorkspace.shared.open(pr.url)
    }
}
