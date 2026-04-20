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
    let userDefaults: UserDefaults

    let dashboardViewModel: DashboardViewModel
    let prDetailViewModel: PRDetailViewModel
    let settingsViewModel: SettingsViewModel

    init(defaults: UserDefaults = .standard) {
        let keychain = KeychainService()
        let events = EventCenter()
        let reporter = events.reporter()

        // Two-phase init: GitHubClient needs an identity-backed token provider,
        // but IdentityActor needs a GitHubClient for validation. Resolve by
        // holding a weak-ish reference via a mutable box assigned after both
        // are constructed.
        let identityHolder = IdentityHolder()

        let gitHubClient = GitHubClient(
            tokenProvider: { await identityHolder.identity?.token() },
            onUnauthorized: { staleToken in
                Task { await identityHolder.identity?.invalidateIfMatchingToken(staleToken, reason: .unauthorized) }
            }
        )
        let identity = IdentityActor(keychain: keychain, github: gitHubClient)
        identityHolder.set(identity)
        let viewsStore = ViewsStore(defaults: defaults, reporter: reporter)
        let gitDirectoriesStore = GitDirectoriesStore(defaults: defaults, reporter: reporter)
        let localRepositoryService = LocalRepositoryService(reporter: reporter)

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
        self.userDefaults = defaults
        self.prDetailViewModel = PRDetailViewModel(gitHubClient: gitHubClient, reporter: reporter)
        self.dashboardViewModel = DashboardViewModel(
            gitHubClient: gitHubClient,
            identity: identity,
            viewsStore: viewsStore,
            localRepositoryService: localRepositoryService,
            defaults: defaults,
            reporter: reporter
        )
        // Synchronously read the stored token once at startup so the initial UI
        // can show "signed in" without awaiting the actor. Writes always go
        // through IdentityActor.
        let initialToken = Self.initialToken(keychain: keychain)
        self.settingsViewModel = SettingsViewModel(
            identity: identity,
            gitHubClient: gitHubClient,
            gitDirectoriesStore: gitDirectoriesStore,
            localRepositoryService: localRepositoryService,
            defaults: defaults,
            reporter: reporter,
            initialToken: initialToken
        )

        // Populate IdentityActor from Keychain (or DEBUG env var) before any fetch.
        Task { await identity.bootstrap() }

        // Start security-scoped access for bookmarked directories
        let initialDirectories = gitDirectoriesStore.load()
        gitDirectoriesStore.startAccessing(initialDirectories)

        // Start auto-refresh independently of window visibility so notifications work
        // even when the window is hidden (menu bar app).
        dashboardViewModel.startAutoRefresh()

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

    // MARK: - Private

    private static func initialToken(keychain: KeychainService) -> String? {
        #if DEBUG
        if let envToken = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !envToken.isEmpty {
            return envToken
        }
        #endif
        return keychain.read(key: Constants.Keychain.githubToken)
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
