import Foundation
import os

@MainActor
@Observable
final class AppState {
    let keychain: KeychainService
    let gitHubClient: GitHubClient
    let viewsStore: ViewsStore
    let identity: IdentityActor
    let gitDirectoriesStore: GitDirectoriesStore
    let localRepositoryService: LocalRepositoryService
    let events: EventCenter
    let logExportService: LogExportService
    let systemAvailabilityMonitor: SystemAvailabilityMonitor
    let userDefaults: UserDefaults

    let dashboardViewModel: DashboardViewModel
    let prDetailViewModel: PRDetailViewModel
    let settingsViewModel: SettingsViewModel

    init(defaults: UserDefaults = .standard) {
        let keychain = KeychainService()
        let events = EventCenter()
        let reporter = events.reporter()

        // One launch-time read feeds both IdentityActor and SettingsViewModel,
        // so the fetch layer and the UI can't disagree about the token.
        let storedToken: String?
        let tokenReadFailure: String?
        do {
            storedToken = try IdentityActor.readStoredToken(from: keychain)
            tokenReadFailure = nil
        } catch {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "PullRequestPilot", category: "AppState")
                .error("Keychain read failed at launch: \(error, privacy: .public)")
            storedToken = nil
            tokenReadFailure = error.localizedDescription
        }

        // Two-phase init: GitHubClient needs an identity-backed token provider,
        // but IdentityActor needs a GitHubClient for validation. Resolve by
        // holding a weak-ish reference via a mutable box assigned after both
        // are constructed.
        let identityHolder = IdentityHolder()

        let gitHubClient = GitHubClient(
            tokenProvider: { await identityHolder.identity?.token() },
            onUnauthorized: { staleToken in
                Task { await identityHolder.identity?.handleUnauthorized(staleToken: staleToken) }
            }
        )
        let identity = IdentityActor(keychain: keychain, github: gitHubClient, storedToken: storedToken)
        identityHolder.set(identity)
        let viewsStore = ViewsStore(defaults: defaults, reporter: reporter)
        let gitDirectoriesStore = GitDirectoriesStore(defaults: defaults, reporter: reporter)
        let localRepositoryService = LocalRepositoryService(reporter: reporter)

        let bundleID = Bundle.main.bundleIdentifier ?? "com.pullrequestpilot.app"
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let logExportService = LogExportService(
            reporter: events.reporter(),
            store: OSLogEntrySource(),
            pasteboard: NSPasteboardAdapter(),
            workspace: NSWorkspaceAdapter(),
            bundleID: bundleID,
            appVersion: appVersion,
            appBuild: appBuild,
            osVersion: osVersion
        )

        // Widget save path reports errors through the same center so the user
        // sees a toast rather than a silent log line.
        WidgetData.setErrorReporter { message in reporter.postError(.widgetSaveFailed(underlying: message)) }

        self.keychain = keychain
        self.identity = identity
        self.gitHubClient = gitHubClient
        self.viewsStore = viewsStore
        self.gitDirectoriesStore = gitDirectoriesStore
        self.localRepositoryService = localRepositoryService
        self.events = events
        self.logExportService = logExportService
        let systemAvailabilityMonitor = SystemAvailabilityMonitor()
        self.systemAvailabilityMonitor = systemAvailabilityMonitor
        self.userDefaults = defaults
        self.prDetailViewModel = PRDetailViewModel(gitHubClient: gitHubClient, reporter: reporter)
        self.dashboardViewModel = DashboardViewModel(
            gitHubClient: gitHubClient,
            identity: identity,
            viewsStore: viewsStore,
            localRepositoryService: localRepositoryService,
            defaults: defaults,
            reporter: reporter,
            availabilityEvents: systemAvailabilityMonitor.events
        )
        self.settingsViewModel = SettingsViewModel(
            identity: identity,
            gitDirectoriesStore: gitDirectoriesStore,
            localRepositoryService: localRepositoryService,
            defaults: defaults,
            reporter: reporter,
            initialToken: storedToken,
            tokenReadFailure: tokenReadFailure
        )

        // Start security-scoped access for bookmarked directories
        let initialDirectories = gitDirectoriesStore.load()
        gitDirectoriesStore.startAccessing(initialDirectories)

        // Start auto-refresh independently of window visibility so notifications work
        // even when the window is hidden (menu bar app). Without a token every tick
        // would fail; signing in starts it instead.
        if storedToken != nil {
            dashboardViewModel.startAutoRefresh()
        }

        // Periodic refresh of local repo index (first tick scans immediately)
        let store = gitDirectoriesStore
        let scanInterval = defaults.double(forKey: Constants.UserDefaultsKeys.repoScanInterval)
        localRepositoryService.startPeriodicRefresh(
            directories: {
                let dirs = store.load()
                // startAccessing is balanced by stopAccessing when directories are
                // removed via SettingsViewModel. For the periodic scan, the initial
                // access started above covers these URLs for the app's lifetime.
                return dirs
            },
            interval: scanInterval > 0 ? scanInterval : Constants.App.defaultRepoScanInterval
        )
    }

    // MARK: - Lifecycle

    func cleanup() {
        dashboardViewModel.stopAutoRefresh()
        localRepositoryService.stopPeriodicRefresh()
        let dirs = gitDirectoriesStore.load()
        gitDirectoriesStore.stopAccessing(dirs)
    }
}

/// Lets GitHubClient's token-provider closure reach IdentityActor without a
/// chicken-and-egg dependency cycle at init time. Single-writer: AppState.init
/// assigns once and then only reads occur.
private final class IdentityHolder: Sendable {
    private let storage = OSAllocatedUnfairLock<IdentityActor?>(initialState: nil)

    var identity: IdentityActor? {
        storage.withLock { $0 }
    }

    func set(_ identity: IdentityActor) {
        storage.withLock { $0 = identity }
    }
}
