import Foundation

@Observable
final class AppState {
    let keychain: KeychainService
    let gitHubClient: GitHubClient

    let reviewQueueViewModel: ReviewQueueViewModel
    let settingsViewModel: SettingsViewModel

    init() {
        let keychain = KeychainService()
        let gitHubClient = GitHubClient(
            tokenProvider: { keychain.read(key: Constants.Keychain.githubToken) }
        )

        self.keychain = keychain
        self.gitHubClient = gitHubClient
        self.reviewQueueViewModel = ReviewQueueViewModel(gitHubClient: gitHubClient)
        self.settingsViewModel = SettingsViewModel(keychain: keychain, gitHubClient: gitHubClient)
    }
}
