import Foundation
import os
import ServiceManagement
import SwiftUI

@MainActor
@Observable
final class SettingsViewModel {
    var token: String = ""
    private(set) var viewerLogin: String?
    private(set) var validationState: ValidationState = .idle
    private(set) var saveError: String?

    private let keychain: KeychainService
    private let gitHubClient: GitHubClientProtocol
    private let tokenCache: TokenCache
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "GitHubDashboard", category: "Settings")

    enum ValidationState: Equatable {
        case idle
        case validating
        case valid
        case invalid(String)
    }

    init(keychain: KeychainService, gitHubClient: GitHubClientProtocol, tokenCache: TokenCache) {
        self.keychain = keychain
        self.gitHubClient = gitHubClient
        self.tokenCache = tokenCache
        self.token = tokenCache.token ?? ""
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

    // MARK: - Launch at Login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                logger.error("Failed to update launch at login: \(error)")
            }
        }
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
