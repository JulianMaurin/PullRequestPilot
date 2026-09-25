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
    /// Set when the saved token works but can't read private repositories.
    private(set) var tokenScopeWarning: String?
    var gitDirectories: [URL] = []
    /// Bookmarked directories that don't resolve right now (disk not mounted,
    /// folder moved); retried on every reload.
    private(set) var unavailableDirectoryPaths: [String] = []
    private(set) var launchAtLoginEnabled: Bool
    private(set) var launchAtLoginError: String?
    /// True while a signed-in user is entering a replacement token.
    private(set) var isChangingToken = false

    private let identity: IdentityActor
    private let gitDirectoriesStore: GitDirectoriesStore
    private let localRepositoryService: LocalRepositoryService
    private let defaults: UserDefaults
    private let reporter: EventReporter
    private let rescanTaskStorage = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    private let invalidationObservationStorage = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    private let logger = Logger(category: "Settings")

    enum ValidationState: Equatable {
        case idle
        case validating
        case valid
        case invalid(String)
    }

    /// Whether a token has been persisted (not just typed in the field).
    /// Used by RootContentView to decide whether to show settings or the dashboard.
    private(set) var hasSavedToken: Bool = false

    /// `tokenReadFailure` describes a Keychain that couldn't be read at launch;
    /// the token field then explains that instead of looking like a first run.
    init(identity: IdentityActor, gitDirectoriesStore: GitDirectoriesStore, localRepositoryService: LocalRepositoryService, defaults: UserDefaults, reporter: EventReporter = .noop, initialToken: String? = nil, tokenReadFailure: String? = nil) {
        self.identity = identity
        self.gitDirectoriesStore = gitDirectoriesStore
        self.localRepositoryService = localRepositoryService
        self.defaults = defaults
        self.reporter = reporter
        self.token = initialToken ?? ""
        self.hasSavedToken = (initialToken?.isEmpty == false)
        if let tokenReadFailure {
            self.validationState = .invalid("Couldn't read your saved token from the Keychain (\(tokenReadFailure)). Unlock the Keychain and relaunch, or paste the token again.")
        }
        self.gitDirectories = gitDirectoriesStore.load()
        self.unavailableDirectoryPaths = gitDirectoriesStore.unavailableDirectoryPaths

        let prInterval = defaults.double(forKey: Constants.UserDefaultsKeys.prRefreshInterval)
        self.prRefreshInterval = prInterval > 0 ? prInterval : Constants.App.defaultPRRefreshInterval
        let repoInterval = defaults.double(forKey: Constants.UserDefaultsKeys.repoScanInterval)
        self.repoScanInterval = repoInterval > 0 ? repoInterval : Constants.App.defaultRepoScanInterval
        self.launchAtLoginEnabled = SMAppService.mainApp.status == .enabled

        let invalidations = identity.invalidations
        let observation = Task { [weak self] in
            for await reason in invalidations where reason == .unauthorized {
                self?.handleTokenRejected()
            }
        }
        invalidationObservationStorage.withLock { $0 = observation }
    }

    deinit {
        rescanTaskStorage.withLock { task in
            task?.cancel()
            task = nil
        }
        invalidationObservationStorage.withLock { task in
            task?.cancel()
            task = nil
        }
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
        tokenScopeWarning = nil
        validationState = .validating

        logger.info("Validating token against GitHub API...")

        do {
            let viewer = try await identity.swap(to: trimmedToken)
            // Committed without another suspension point, so a Sign Out
            // confirmed mid-save can't be overwritten by a late resume.
            viewerLogin = viewer.login
            viewerAvatarURL = viewer.avatarURL
            tokenScopeWarning = viewer.lacksPrivateRepositoryAccess ? Self.missingRepoScopeWarning : nil
            isChangingToken = false
            hasSavedToken = true
            validationState = .valid
            reporter.resolve { error in
                switch error {
                case .unauthorized, .permissionDenied, .tokenSaveFailed: return true
                default: return false
                }
            }
            logger.info("Token validated — authenticated as \(viewer.login, privacy: .private)")
        } catch is CancellationError {
            validationState = .idle
            return
        } catch let authError as AuthError {
            logger.error("Token swap failed: \(authError.localizedDescription, privacy: .public)")
            switch authError.reason {
            case .saveFailed:
                saveError = authError.localizedDescription
                validationState = .idle
                reporter.postError(.tokenSaveFailed(underlying: authError.localizedDescription))
            case .invalidToken, .network, .unauthorized, .userSignedOut, .unknown:
                validationState = .invalid(userMessage(for: authError))
            }
        } catch {
            logger.error("Unexpected error during token validation: \(error, privacy: .public)")
            validationState = .invalid("Something went wrong. Check the logs for details.")
        }
    }

    static let missingRepoScopeWarning = "This token doesn't have the repo scope, so pull requests in private repositories won't appear. Create a token with the repo scope to see them."

    func clearToken() async {
        await identity.invalidate(reason: .userSignedOut)
        token = ""
        viewerLogin = nil
        viewerAvatarURL = nil
        tokenScopeWarning = nil
        isChangingToken = false
        validationState = .idle
        hasSavedToken = false
        logger.info("Token cleared")
    }

    /// Shows the token field while signed in; the current token stays active
    /// until a replacement validates.
    func beginChangingToken() {
        token = ""
        saveError = nil
        validationState = .idle
        isChangingToken = true
    }

    func cancelChangingToken() {
        token = ""
        saveError = nil
        validationState = .idle
        isChangingToken = false
    }

    /// GitHub confirmed the saved token is revoked or expired. Views stay; the
    /// token field comes back with an explanation.
    private func handleTokenRejected() {
        logger.info("Saved token rejected by GitHub; asking for a new one")
        token = ""
        viewerLogin = nil
        viewerAvatarURL = nil
        tokenScopeWarning = nil
        isChangingToken = false
        hasSavedToken = false
        validationState = .invalid("GitHub rejected the saved token — it may have expired or been revoked. Paste a new one to continue; your views are kept.")
    }

    // MARK: - Launch at Login

    var launchAtLogin: Bool {
        get { launchAtLoginEnabled }
        set {
            launchAtLoginError = nil
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            } catch {
                logger.error("Failed to update launch at login: \(error, privacy: .public)")
                launchAtLoginError = "Could not update launch at login setting."
                reporter.postError(.launchAtLoginFailed(underlying: error.localizedDescription))
            }
        }
    }

    /// Call when the window gains focus so the Toggle reflects changes made in
    /// System Settings → Login Items while Settings was open.
    func refreshLaunchAtLoginStatus() {
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
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
            guard gitDirectoriesStore.saveFromPanel(url) != nil else {
                logger.error("Failed to create security-scoped bookmark for \(url.path, privacy: .private)")
                reporter.postError(.bookmarkCreationFailed(path: url.lastPathComponent))
                return
            }
            gitDirectories.append(url)
            triggerRescan()
        }
    }

    func removeGitDirectory(_ url: URL) {
        gitDirectoriesStore.stopAccessing([url])
        gitDirectories.removeAll { $0 == url }
        gitDirectoriesStore.save(gitDirectories)
        triggerRescan()
    }

    func removeUnavailableDirectory(atPath path: String) {
        gitDirectoriesStore.removeUnavailableDirectory(atPath: path)
        unavailableDirectoryPaths = gitDirectoriesStore.unavailableDirectoryPaths
    }

    /// Re-resolves the bookmarks, picking up directories whose disk came back.
    func reloadGitDirectories() {
        let directories = gitDirectoriesStore.load()
        if directories != gitDirectories {
            gitDirectories = directories
        }
        unavailableDirectoryPaths = gitDirectoriesStore.unavailableDirectoryPaths
    }

    func rescan() {
        triggerRescan()
    }

    private func triggerRescan() {
        let snapshot = gitDirectories
        let service = localRepositoryService
        rescanTaskStorage.withLock { existing in
            existing?.cancel()
            existing = Task {
                await service.scan(directories: snapshot)
            }
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
            case .permissionDenied:
                return "GitHub refused the request. The token may lack the required `repo` scope."
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
