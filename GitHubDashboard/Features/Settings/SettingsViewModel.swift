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
    var gitDirectories: [URL] = []

    private let keychain: KeychainService
    private let gitHubClient: GitHubClientProtocol
    private let tokenCache: TokenCache
    private let gitDirectoriesStore: GitDirectoriesStore
    private let localRepositoryService: LocalRepositoryService
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "GitHubDashboard", category: "Settings")

    enum ValidationState: Equatable {
        case idle
        case validating
        case valid
        case invalid(String)
    }

    init(keychain: KeychainService, gitHubClient: GitHubClientProtocol, tokenCache: TokenCache, gitDirectoriesStore: GitDirectoriesStore, localRepositoryService: LocalRepositoryService) {
        self.keychain = keychain
        self.gitHubClient = gitHubClient
        self.tokenCache = tokenCache
        self.gitDirectoriesStore = gitDirectoriesStore
        self.localRepositoryService = localRepositoryService
        self.token = tokenCache.token ?? ""
        self.gitDirectories = gitDirectoriesStore.load()

        let prInterval = UserDefaults.standard.double(forKey: Constants.UserDefaultsKeys.prRefreshInterval)
        self.prRefreshInterval = prInterval > 0 ? prInterval : Constants.App.defaultPRRefreshInterval
        let repoInterval = UserDefaults.standard.double(forKey: Constants.UserDefaultsKeys.repoScanInterval)
        self.repoScanInterval = repoInterval > 0 ? repoInterval : Constants.App.defaultRepoScanInterval
    }

    var isScanning: Bool { localRepositoryService.isScanning }
    var lastScanDate: Date? { localRepositoryService.lastScanDate }
    var indexedRepoCount: Int { localRepositoryService.indexedRepoCount }

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

    // MARK: - Refresh Intervals

    var prRefreshInterval: TimeInterval {
        didSet {
            UserDefaults.standard.set(prRefreshInterval, forKey: Constants.UserDefaultsKeys.prRefreshInterval)
            NotificationCenter.default.post(name: Constants.Notifications.prRefreshIntervalChanged, object: nil)
        }
    }

    var repoScanInterval: TimeInterval {
        didSet {
            UserDefaults.standard.set(repoScanInterval, forKey: Constants.UserDefaultsKeys.repoScanInterval)
            restartRepoScan()
        }
    }

    static let refreshIntervalOptions: [(label: String, value: TimeInterval)] = [
        ("30 seconds", 30),
        ("1 minute", 60),
        ("2 minutes", 120),
        ("5 minutes", 300),
        ("10 minutes", 600),
        ("30 minutes", 1800),
    ]

    private func restartRepoScan() {
        let dirs = gitDirectories
        localRepositoryService.stopPeriodicRefresh()
        let store = gitDirectoriesStore
        localRepositoryService.startPeriodicRefresh(
            directories: { store.load() },
            interval: repoScanInterval
        )
    }

    // MARK: - Git Directories

    func addGitDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a directory containing git repositories"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        if !gitDirectories.contains(url) {
            gitDirectories.append(url)
            gitDirectoriesStore.save(gitDirectories)
            triggerRescan()
        }
    }

    func removeGitDirectory(at offsets: IndexSet) {
        gitDirectories.remove(atOffsets: offsets)
        gitDirectoriesStore.save(gitDirectories)
        triggerRescan()
    }

    func removeGitDirectory(_ url: URL) {
        gitDirectories.removeAll { $0 == url }
        gitDirectoriesStore.save(gitDirectories)
        triggerRescan()
    }

    func rescan() {
        triggerRescan()
    }

    private func triggerRescan() {
        Task {
            await localRepositoryService.scan(directories: gitDirectories)
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
