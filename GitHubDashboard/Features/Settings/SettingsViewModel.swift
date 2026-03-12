import Foundation
import os
import SwiftUI

@MainActor
@Observable
final class SettingsViewModel {
    var token: String = ""
    private(set) var viewerLogin: String?
    private(set) var validationState: ValidationState = .idle
    private(set) var saveError: String?

    var editableViews: [DashboardView] = []

    private let keychain: KeychainService
    private let gitHubClient: GitHubClientProtocol
    private let viewsStore: ViewsStore
    private let tokenCache: TokenCache
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "GitHubDashboard", category: "Settings")

    enum ValidationState: Equatable {
        case idle
        case validating
        case valid
        case invalid(String)
    }

    init(keychain: KeychainService, gitHubClient: GitHubClientProtocol, viewsStore: ViewsStore, tokenCache: TokenCache) {
        self.keychain = keychain
        self.gitHubClient = gitHubClient
        self.viewsStore = viewsStore
        self.tokenCache = tokenCache
        self.token = tokenCache.token ?? ""
        self.editableViews = viewsStore.load()
    }

    var hasToken: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Token

    func save() async {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        saveError = nil
        validationState = .validating

        logger.info("Saving GitHub token to Keychain...")

        do {
            try keychain.save(key: Constants.Keychain.githubToken, value: trimmedToken)
            tokenCache.set(trimmedToken)
            logger.info("Token saved to Keychain successfully")
        } catch {
            logger.error("Failed to save token to Keychain: \(error)")
            saveError = "Could not save token to Keychain. Check that the app has Keychain access."
            validationState = .idle
            return
        }

        logger.info("Validating token against GitHub API...")

        do {
            let login = try await gitHubClient.fetchViewerLogin()
            viewerLogin = login
            validationState = .valid
            logger.info("Token validated — authenticated as \(login)")
        } catch let error as GitHubClientError {
            logger.error("Token validation failed: \(error.localizedDescription)")
            validationState = .invalid(userMessage(for: error))
        } catch {
            logger.error("Unexpected error during token validation: \(error)")
            validationState = .invalid("Something went wrong. Check the logs for details.")
        }
    }

    func clearToken() {
        do {
            try keychain.delete(key: Constants.Keychain.githubToken)
            tokenCache.invalidate()
            logger.info("Token cleared from Keychain")
        } catch {
            logger.error("Failed to clear token from Keychain: \(error)")
        }
        token = ""
        viewerLogin = nil
        validationState = .idle
    }

    // MARK: - Views

    func addView(title: String, query: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedQuery.isEmpty else { return }
        editableViews.append(DashboardView(id: UUID(), title: trimmedTitle, query: trimmedQuery))
    }

    func deleteView(at offsets: IndexSet) {
        editableViews.remove(atOffsets: offsets)
        saveViews()
    }

    func deleteView(id: UUID) {
        editableViews.removeAll { $0.id == id }
        saveViews()
    }

    func saveViews() {
        let valid = editableViews.filter {
            !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        viewsStore.save(valid)
    }

    // MARK: - Private

    private func userMessage(for error: GitHubClientError) -> String {
        switch error {
        case .unauthorized:
            "Token is invalid or expired. Generate a new one at github.com/settings/tokens."
        case .graphQLErrors:
            "GitHub rejected the request. The token may lack the required `repo` scope."
        case .networkError:
            "Could not reach GitHub. Check your internet connection and try again."
        case .decodingError:
            "Received an unexpected response from GitHub. Try again later."
        }
    }
}
