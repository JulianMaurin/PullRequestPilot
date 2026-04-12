import Foundation

@MainActor
@Observable
final class AppState {
    let keychain: KeychainService
    let gitHubClient: GitHubClient
    let viewsStore: ViewsStore
    let tokenCache: TokenCache
    let gitDirectoriesStore: GitDirectoriesStore
    let localRepositoryService: LocalRepositoryService

    let dashboardViewModel: DashboardViewModel
    let prDetailViewModel: PRDetailViewModel
    let settingsViewModel: SettingsViewModel

    init(defaults: UserDefaults = .standard) {
        let keychain = KeychainService()
        let tokenCache = TokenCache(keychain: keychain)
        let gitHubClient = GitHubClient(
            tokenProvider: { tokenCache.token },
            onUnauthorized: { staleToken in tokenCache.invalidateIfCurrent(staleToken) }
        )
        let viewsStore = ViewsStore(defaults: defaults)
        let gitDirectoriesStore = GitDirectoriesStore()
        let localRepositoryService = LocalRepositoryService()

        self.keychain = keychain
        self.tokenCache = tokenCache
        self.gitHubClient = gitHubClient
        self.viewsStore = viewsStore
        self.gitDirectoriesStore = gitDirectoriesStore
        self.localRepositoryService = localRepositoryService
        self.prDetailViewModel = PRDetailViewModel(gitHubClient: gitHubClient)
        self.dashboardViewModel = DashboardViewModel(
            gitHubClient: gitHubClient,
            viewsStore: viewsStore,
            localRepositoryService: localRepositoryService,
            defaults: defaults
        )
        self.settingsViewModel = SettingsViewModel(
            keychain: keychain,
            gitHubClient: gitHubClient,
            tokenCache: tokenCache,
            gitDirectoriesStore: gitDirectoriesStore,
            localRepositoryService: localRepositoryService,
            defaults: defaults
        )

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

    // MARK: - Lifecycle

    func cleanup() {
        dashboardViewModel.stopAutoRefresh()
        localRepositoryService.stopPeriodicRefresh()
        let dirs = gitDirectoriesStore.load()
        gitDirectoriesStore.stopAccessing(dirs)
    }
}
