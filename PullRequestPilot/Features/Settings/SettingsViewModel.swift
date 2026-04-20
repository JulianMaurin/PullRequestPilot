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
    private(set) var staleDirectoryWarning: String?

    private(set) var launchAtLoginError: String?

    private let identity: IdentityActor
    private let gitHubClient: GitHubClientProtocol
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

    /// Whether a token has been persisted (not just typed in the field).
    /// Used by RootContentView to decide whether to show settings or the dashboard.
    private(set) var hasSavedToken: Bool = false

    init(identity: IdentityActor, gitHubClient: GitHubClientProtocol, gitDirectoriesStore: GitDirectoriesStore, localRepositoryService: LocalRepositoryService, defaults: UserDefaults = .standard, initialToken: String? = nil) {
        self.identity = identity
        self.gitHubClient = gitHubClient
        self.gitDirectoriesStore = gitDirectoriesStore
        self.localRepositoryService = localRepositoryService
        self.defaults = defaults
        self.token = initialToken ?? ""
        self.hasSavedToken = (initialToken?.isEmpty == false)
        self.gitDirectories = gitDirectoriesStore.load()
        if gitDirectoriesStore.lastPrunedStaleCount > 0 {
            let count = gitDirectoriesStore.lastPrunedStaleCount
            self.staleDirectoryWarning = "\(count) directory bookmark\(count == 1 ? " was" : "s were") removed because \(count == 1 ? "it is" : "they are") no longer accessible. Re-add \(count == 1 ? "it" : "them") using the Add Directory button."
        }

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

        logger.info("Validating token against GitHub API...")

        do {
            let login = try await identity.swap(to: trimmedToken)
            viewerLogin = login
            // Pull avatar in a follow-up call — swap only returns the login.
            viewerAvatarURL = (try? await gitHubClient.validateToken(trimmedToken).avatarURL)
            hasSavedToken = true
            validationState = .valid
            logger.info("Token validated — authenticated as \(login, privacy: .private)")
        } catch is CancellationError {
            validationState = .idle
            return
        } catch let authError as AuthError {
            logger.error("Token swap failed: \(authError.localizedDescription, privacy: .public)")
            switch authError.reason {
            case .saveFailed:
                saveError = authError.localizedDescription
                validationState = .idle
            case .invalidToken, .network, .unauthorized, .userSignedOut, .unknown:
                validationState = .invalid(userMessage(for: authError))
            }
        } catch {
            logger.error("Unexpected error during token validation: \(error, privacy: .public)")
            validationState = .invalid("Something went wrong. Check the logs for details.")
        }
    }

    func clearToken() async {
        await identity.invalidate(reason: .userSignedOut)
        token = ""
        viewerLogin = nil
        viewerAvatarURL = nil
        validationState = .idle
        hasSavedToken = false
        logger.info("Token cleared")
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

    func restartRepoScan() {
        localRepositoryService.stopPeriodicRefresh()
        let store = gitDirectoriesStore
        localRepositoryService.startPeriodicRefresh(
            directories: {
                // startAccessing is balanced by stopAccessing when directories are
                // removed via SettingsViewModel. The initial access started in
                // AppState.init() covers these URLs for the app's lifetime.
                store.load()
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

    private func userMessage(for authError: AuthError) -> String {
        if let clientError = authError.underlying as? GitHubClientError {
            switch clientError {
            case .unauthorized:
                return "Token is invalid or expired. Generate a new one at github.com/settings/tokens."
            case .rateLimited:
                return "GitHub API rate limit exceeded. Wait a few minutes and try again."
            case .clientError:
                return "GitHub rejected the request. Check your query or token permissions."
            case .serverError:
                return "GitHub is experiencing issues. Try again later."
            case .graphQLErrors:
                return "GitHub rejected the request. The token may lack the required `repo` scope."
            case .networkError:
                return "Could not reach GitHub. Check your internet connection and try again."
            case .decodingError:
                return "Received an unexpected response from GitHub. Try again later."
            }
        }
        return authError.localizedDescription
    }
}
