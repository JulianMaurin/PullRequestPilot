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
    let settingsViewModel: SettingsViewModel

    init() {
        let keychain = KeychainService()
        let tokenCache = TokenCache(keychain: keychain)
        let gitHubClient = GitHubClient(
            tokenProvider: { tokenCache.token }
        )
        let viewsStore = ViewsStore()
        let gitDirectoriesStore = GitDirectoriesStore()
        let localRepositoryService = LocalRepositoryService()

        self.keychain = keychain
        self.tokenCache = tokenCache
        self.gitHubClient = gitHubClient
        self.viewsStore = viewsStore
        self.gitDirectoriesStore = gitDirectoriesStore
        self.localRepositoryService = localRepositoryService
        self.dashboardViewModel = DashboardViewModel(
            gitHubClient: gitHubClient,
            viewsStore: viewsStore,
            localRepositoryService: localRepositoryService
        )
        self.settingsViewModel = SettingsViewModel(
            keychain: keychain,
            gitHubClient: gitHubClient,
            tokenCache: tokenCache,
            gitDirectoriesStore: gitDirectoriesStore,
            localRepositoryService: localRepositoryService
        )

        // Start security-scoped access for bookmarked directories
        let initialDirectories = gitDirectoriesStore.load()
        gitDirectoriesStore.startAccessing(initialDirectories)

        // Initial scan + periodic refresh of local repo index
        let store = gitDirectoriesStore
        Task {
            await localRepositoryService.scan(directories: initialDirectories)
        }
        let scanInterval = UserDefaults.standard.double(forKey: Constants.UserDefaultsKeys.repoScanInterval)
        localRepositoryService.startPeriodicRefresh(
            directories: {
                let dirs = store.load()
                store.startAccessing(dirs)
                return dirs
            },
            interval: scanInterval > 0 ? scanInterval : Constants.App.defaultRepoScanInterval
        )
    }
}
