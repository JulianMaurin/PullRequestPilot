import Foundation

@MainActor
@Observable
final class AppState {
    let keychain: KeychainService
    let gitHubClient: GitHubClient
    let viewsStore: ViewsStore
    let tokenCache: TokenCache

    let dashboardViewModel: DashboardViewModel
    let settingsViewModel: SettingsViewModel

    init() {
        let keychain = KeychainService()
        let tokenCache = TokenCache(keychain: keychain)
        let gitHubClient = GitHubClient(
            tokenProvider: { tokenCache.token }
        )
        let viewsStore = ViewsStore()

        self.keychain = keychain
        self.tokenCache = tokenCache
        self.gitHubClient = gitHubClient
        self.viewsStore = viewsStore
        self.dashboardViewModel = DashboardViewModel(gitHubClient: gitHubClient, viewsStore: viewsStore)
        self.settingsViewModel = SettingsViewModel(keychain: keychain, gitHubClient: gitHubClient, tokenCache: tokenCache)
    }
}
