import AppKit
import Foundation
import os
import ServiceManagement

@MainActor
@Observable
final class SettingsViewModel {
    var token: String = ""
    private(set) var viewerLogin: String?
    private(set) var viewerAvatarURL: URL?
    private(set) var validationState: ValidationState = .idle
    private(set) var saveError: String?
    var gitDirectories: [URL] = []

    private(set) var launchAtLoginError: String?

    private let keychain: KeychainService
    private let gitHubClient: GitHubClientProtocol
    private let tokenCache: TokenCache
    private let gitDirectoriesStore: GitDirectoriesStore
    private let localRepositoryService: LocalRepositoryService
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PullRequestPilot", category: "Settings")

    enum ValidationState: Equatable {
        case idle
        case validating
        case valid
        case invalid(String)
    }

    /// Whether a token has been persisted to the Keychain (not just typed in the field).
    /// Used by ContentView to decide whether to show settings or the dashboard.
    private(set) var hasSavedToken: Bool = false

    init(keychain: KeychainService, gitHubClient: GitHubClientProtocol, tokenCache: TokenCache, gitDirectoriesStore: GitDirectoriesStore, localRepositoryService: LocalRepositoryService, defaults: UserDefaults = .standard) {
        self.keychain = keychain
        self.gitHubClient = gitHubClient
        self.tokenCache = tokenCache
        self.gitDirectoriesStore = gitDirectoriesStore
        self.localRepositoryService = localRepositoryService
        self.defaults = defaults
        self.token = tokenCache.token ?? ""
        self.hasSavedToken = tokenCache.token != nil
        self.gitDirectories = gitDirectoriesStore.load()

        let prInterval = defaults.double(forKey: Constants.UserDefaultsKeys.prRefreshInterval)
        self.prRefreshInterval = prInterval > 0 ? prInterval : Constants.App.defaultPRRefreshInterval
        let repoInterval = defaults.double(forKey: Constants.UserDefaultsKeys.repoScanInterval)
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

        // Temporarily set in cache so the API client can use it for validation
        tokenCache.set(trimmedToken)

        logger.info("Validating token against GitHub API...")

        do {
            let viewer = try await gitHubClient.fetchViewer()
            viewerLogin = viewer.login
            viewerAvatarURL = viewer.avatarURL
            validationState = .valid
            logger.info("Token validated — authenticated as \(viewer.login, privacy: .private)")
        } catch let error as GitHubClientError {
            logger.error("Token validation failed: \(error.localizedDescription, privacy: .public)")
            tokenCache.invalidate()
            validationState = .invalid(userMessage(for: error))
            return
        } catch {
            logger.error("Unexpected error during token validation: \(error, privacy: .public)")
            tokenCache.invalidate()
            validationState = .invalid("Something went wrong. Check the logs for details.")
            return
        }

        // Validation succeeded — persist to Keychain
        logger.info("Saving GitHub token to Keychain...")

        do {
            try keychain.save(key: Constants.Keychain.githubToken, value: trimmedToken)
            hasSavedToken = true
            logger.info("Token saved to Keychain successfully")
        } catch {
            logger.error("Failed to save token to Keychain: \(error, privacy: .public)")
            saveError = "Could not save token to Keychain. Check that the app has Keychain access."
            validationState = .idle
        }
    }

    func clearToken() {
        do {
            try keychain.delete(key: Constants.Keychain.githubToken)
            tokenCache.invalidate()
            logger.info("Token cleared from Keychain")
        } catch {
            logger.error("Failed to clear token from Keychain: \(error, privacy: .public)")
        }
        token = ""
        viewerLogin = nil
        viewerAvatarURL = nil
        validationState = .idle
        hasSavedToken = false
    }

    // MARK: - Launch at Login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            launchAtLoginError = nil
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                logger.error("Failed to update launch at login: \(error, privacy: .public)")
                launchAtLoginError = "Could not update launch at login setting."
            }
        }
    }

    // MARK: - Refresh Intervals

    var prRefreshInterval: TimeInterval {
        didSet {
            defaults.set(prRefreshInterval, forKey: Constants.UserDefaultsKeys.prRefreshInterval)
            NotificationCenter.default.post(name: Constants.Notifications.prRefreshIntervalChanged, object: nil)
        }
    }

    var repoScanInterval: TimeInterval {
        didSet {
            defaults.set(repoScanInterval, forKey: Constants.UserDefaultsKeys.repoScanInterval)
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
        localRepositoryService.stopPeriodicRefresh()
        let store = gitDirectoriesStore
        localRepositoryService.startPeriodicRefresh(
            directories: {
                let dirs = store.load()
                store.startAccessing(dirs)
                return dirs
            },
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
            guard gitDirectoriesStore.saveFromPanel(url) != nil else {
                logger.error("Failed to create security-scoped bookmark for \(url.path, privacy: .private)")
                return
            }
            gitDirectories.append(url)
            triggerRescan()
        }
    }

    func removeGitDirectory(at offsets: IndexSet) {
        let removing = offsets.map { gitDirectories[$0] }
        gitDirectoriesStore.stopAccessing(removing)
        gitDirectories.remove(atOffsets: offsets)
        gitDirectoriesStore.save(gitDirectories)
        triggerRescan()
    }

    func removeGitDirectory(_ url: URL) {
        gitDirectoriesStore.stopAccessing([url])
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
        case .rateLimited:
            "GitHub API rate limit exceeded. Wait a few minutes and try again."
        case .serverError:
            "GitHub is experiencing issues. Try again later."
        case .graphQLErrors:
            "GitHub rejected the request. The token may lack the required `repo` scope."
        case .networkError:
            "Could not reach GitHub. Check your internet connection and try again."
        case .decodingError:
            "Received an unexpected response from GitHub. Try again later."
        }
    }
}
