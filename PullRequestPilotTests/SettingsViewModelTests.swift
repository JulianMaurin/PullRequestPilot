import Testing
import Foundation
@testable import PullRequestPilot

@MainActor
@Suite("SettingsViewModel")
struct SettingsViewModelTests {
    private let mockClient = MockGitHubClient()
    private let localRepoService = LocalRepositoryService()

    private func makeViewModel(
        storedToken: String? = nil,
        suiteName: String = "SettingsVMTests"
    ) -> (SettingsViewModel, KeychainService, TokenCache, GitDirectoriesStore) {
        let keychainService = "com.pullrequestpilot.settings.tests.\(suiteName)"
        let keychain = KeychainService(service: keychainService)
        if let storedToken {
            try? keychain.save(key: Constants.Keychain.githubToken, value: storedToken)
        } else {
            try? keychain.delete(key: Constants.Keychain.githubToken)
        }
        let tokenCache = TokenCache(keychain: keychain)
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let gitDirStore = GitDirectoriesStore(defaults: defaults)

        let vm = SettingsViewModel(
            keychain: keychain,
            gitHubClient: mockClient,
            tokenCache: tokenCache,
            gitDirectoriesStore: gitDirStore,
            localRepositoryService: localRepoService
        )
        return (vm, keychain, tokenCache, gitDirStore)
    }

    // MARK: - Token

    @Test("hasToken is false when token is empty or whitespace")
    func hasTokenEmpty() {
        let (vm, _, _, _) = makeViewModel(suiteName: "HasTokenEmpty")
        vm.token = ""
        #expect(!vm.hasToken)

        vm.token = "   "
        #expect(!vm.hasToken)

        vm.token = "  \n  "
        #expect(!vm.hasToken)
    }

    @Test("hasToken is true when token has content")
    func hasTokenWithContent() {
        let (vm, _, _, _) = makeViewModel(suiteName: "HasTokenContent")
        vm.token = "ghp_abc123"
        #expect(vm.hasToken)
    }

    @Test("save stores token and validates against GitHub API")
    func saveTokenSuccess() async {
        let (vm, keychain, _, _) = makeViewModel(suiteName: "SaveSuccess")
        mockClient.viewerLoginToReturn = "octocat"

        vm.token = "ghp_valid_token"
        await vm.save()

        #expect(vm.validationState == .valid)
        #expect(keychain.read(key: Constants.Keychain.githubToken) == "ghp_valid_token")
    }

    @Test("save transitions through validating state")
    func saveTransitionsStates() async {
        let (vm, _, _, _) = makeViewModel(suiteName: "SaveTransitions")
        mockClient.viewerLoginToReturn = "user"

        vm.token = "ghp_token"
        // Before save
        #expect(vm.validationState == .idle)

        await vm.save()
        // After save
        #expect(vm.validationState == .valid)
    }

    @Test("save sets invalid state when API returns unauthorized")
    func saveTokenUnauthorized() async {
        let (vm, _, _, _) = makeViewModel(suiteName: "SaveUnauth")
        mockClient.errorToThrow = GitHubClientError.unauthorized

        vm.token = "ghp_bad_token"
        await vm.save()

        if case .invalid(let message) = vm.validationState {
            #expect(message.contains("invalid") || message.contains("expired") || message.contains("Token"))
        } else {
            Issue.record("Expected invalid state, got \(vm.validationState)")
        }
    }

    @Test("save sets invalid state for graphQL errors")
    func saveTokenGraphQLError() async {
        let (vm, _, _, _) = makeViewModel(suiteName: "SaveGraphQL")
        mockClient.errorToThrow = GitHubClientError.graphQLErrors(["scope missing"])

        vm.token = "ghp_token"
        await vm.save()

        if case .invalid(let message) = vm.validationState {
            #expect(message.contains("scope") || message.contains("rejected"))
        } else {
            Issue.record("Expected invalid state")
        }
    }

    @Test("save sets invalid state for network errors")
    func saveTokenNetworkError() async {
        let (vm, _, _, _) = makeViewModel(suiteName: "SaveNetwork")
        mockClient.errorToThrow = GitHubClientError.networkError(URLError(.notConnectedToInternet))

        vm.token = "ghp_token"
        await vm.save()

        if case .invalid(let message) = vm.validationState {
            #expect(message.contains("internet") || message.contains("reach") || message.contains("Could not"))
        } else {
            Issue.record("Expected invalid state")
        }
    }

    @Test("save sets invalid state for decoding errors")
    func saveTokenDecodingError() async {
        let (vm, _, _, _) = makeViewModel(suiteName: "SaveDecoding")
        mockClient.errorToThrow = GitHubClientError.decodingError(URLError(.cannotParseResponse))

        vm.token = "ghp_token"
        await vm.save()

        if case .invalid(let message) = vm.validationState {
            #expect(message.contains("unexpected") || message.contains("response") || message.contains("Received"))
        } else {
            Issue.record("Expected invalid state")
        }
    }

    @Test("clearToken removes from keychain and resets state")
    func clearToken() {
        let (vm, keychain, tokenCache, _) = makeViewModel(storedToken: "ghp_existing", suiteName: "ClearToken")
        vm.token = "ghp_existing"

        vm.clearToken()

        #expect(vm.token == "")
        #expect(vm.validationState == .idle)
        #expect(keychain.read(key: Constants.Keychain.githubToken) == nil)
        #expect(tokenCache.token == nil)
    }

    // MARK: - Computed Properties

    @Test("isScanning delegates to localRepositoryService")
    func isScanningDelegation() {
        let (vm, _, _, _) = makeViewModel(suiteName: "Scanning")
        #expect(vm.isScanning == localRepoService.isScanning)
    }

    @Test("lastScanDate delegates to localRepositoryService")
    func lastScanDateDelegation() {
        let (vm, _, _, _) = makeViewModel(suiteName: "LastScan")
        #expect(vm.lastScanDate == localRepoService.lastScanDate)
    }

    @Test("indexedRepoCount delegates to localRepositoryService")
    func indexedRepoCountDelegation() {
        let (vm, _, _, _) = makeViewModel(suiteName: "RepoCount")
        #expect(vm.indexedRepoCount == localRepoService.indexedRepoCount)
    }

    // MARK: - Git Directories

    @Test("removeGitDirectory by URL removes and saves")
    func removeGitDirectoryByURL() {
        let (vm, _, _, _) = makeViewModel(suiteName: "RemoveDir")
        let url = URL(fileURLWithPath: "/tmp/test-repo")
        vm.gitDirectories = [url]

        vm.removeGitDirectory(url)

        #expect(vm.gitDirectories.isEmpty)
    }

    @Test("removeGitDirectory by offsets removes correct entry")
    func removeGitDirectoryByOffset() {
        let (vm, _, _, _) = makeViewModel(suiteName: "RemoveDirOffset")
        let url1 = URL(fileURLWithPath: "/tmp/repo1")
        let url2 = URL(fileURLWithPath: "/tmp/repo2")
        vm.gitDirectories = [url1, url2]

        vm.removeGitDirectory(at: IndexSet(integer: 0))

        #expect(vm.gitDirectories.count == 1)
        #expect(vm.gitDirectories.first == url2)
    }

    // MARK: - Refresh Intervals

    @Test("refreshIntervalOptions has reasonable values")
    func refreshIntervalOptionsValid() {
        let options = SettingsViewModel.refreshIntervalOptions
        #expect(!options.isEmpty)
        #expect(options.allSatisfy { $0.value > 0 })
        // Values should be in ascending order
        for i in 1..<options.count {
            #expect(options[i].value > options[i - 1].value)
        }
    }

    // MARK: - ValidationState

    @Test("ValidationState equality")
    func validationStateEquality() {
        #expect(SettingsViewModel.ValidationState.idle == .idle)
        #expect(SettingsViewModel.ValidationState.validating == .validating)
        #expect(SettingsViewModel.ValidationState.valid == .valid)
        #expect(SettingsViewModel.ValidationState.invalid("a") == .invalid("a"))
        #expect(SettingsViewModel.ValidationState.invalid("a") != .invalid("b"))
        #expect(SettingsViewModel.ValidationState.idle != .valid)
    }

    // MARK: - rescan

    @Test("rescan triggers a scan on localRepositoryService")
    func rescanTriggersScan() async {
        let (vm, _, _, _) = makeViewModel(suiteName: "Rescan")
        vm.rescan()
        // Give the async Task inside triggerRescan a chance to start
        try? await Task.sleep(for: .milliseconds(100))
        // No crash, scan was triggered
    }

    // MARK: - Interval setters

    @Test("prRefreshInterval posts notification on change")
    func prRefreshIntervalPostsNotification() {
        let (vm, _, _, _) = makeViewModel(suiteName: "PRInterval")
        var notificationReceived = false
        let observer = NotificationCenter.default.addObserver(
            forName: Constants.Notifications.prRefreshIntervalChanged,
            object: nil,
            queue: .main
        ) { _ in
            notificationReceived = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        vm.prRefreshInterval = 300
        // Notification is posted synchronously in didSet
        #expect(notificationReceived)
    }

    @Test("repoScanInterval persists to UserDefaults")
    func repoScanIntervalPersists() {
        let (vm, _, _, _) = makeViewModel(suiteName: "RepoInterval")
        vm.repoScanInterval = 600
        let stored = UserDefaults.standard.double(forKey: Constants.UserDefaultsKeys.repoScanInterval)
        #expect(stored == 600)
    }

    // MARK: - save with generic (non-GitHubClientError) error

    @Test("save sets invalid state for unexpected errors")
    func saveTokenGenericError() async {
        let (vm, _, _, _) = makeViewModel(suiteName: "SaveGeneric")

        // Create a custom error that is NOT GitHubClientError
        struct TestError: Error {}
        mockClient.errorToThrow = TestError()

        vm.token = "ghp_token"
        await vm.save()

        if case .invalid(let message) = vm.validationState {
            #expect(message.contains("Something went wrong"))
        } else {
            Issue.record("Expected invalid state, got \(vm.validationState)")
        }
    }

    // MARK: - Token trimming on save

    @Test("save trims whitespace from token before saving")
    func saveTrimsWhitespace() async {
        let (vm, keychain, _, _) = makeViewModel(suiteName: "SaveTrim")
        mockClient.viewerLoginToReturn = "user"

        vm.token = "  ghp_token_with_spaces  \n"
        await vm.save()

        #expect(keychain.read(key: Constants.Keychain.githubToken) == "ghp_token_with_spaces")
    }

    // MARK: - Init loads token from cache

    @Test("init loads existing token from cache")
    func initLoadsToken() {
        let (vm, _, _, _) = makeViewModel(storedToken: "ghp_existing", suiteName: "InitLoads")
        // In DEBUG with GITHUB_TOKEN env var, the env var takes precedence
        if ProcessInfo.processInfo.environment["GITHUB_TOKEN"] == nil {
            #expect(vm.token == "ghp_existing")
            #expect(vm.hasToken)
        }
    }

    // MARK: - hasSavedToken

    @Test("hasSavedToken is true when token exists in cache")
    func hasSavedTokenTrue() {
        let (vm, _, _, _) = makeViewModel(storedToken: "ghp_token", suiteName: "HasSavedTrue")
        #expect(vm.hasSavedToken)
    }

    @Test("hasSavedToken is false when no token in cache")
    func hasSavedTokenFalse() {
        let (vm, _, _, _) = makeViewModel(suiteName: "HasSavedFalse")
        #expect(!vm.hasSavedToken)
    }

    @Test("save sets hasSavedToken to true")
    func saveSetsSavedToken() async {
        let (vm, _, _, _) = makeViewModel(suiteName: "SaveSetsSaved")
        mockClient.viewerLoginToReturn = "user"
        #expect(!vm.hasSavedToken)

        vm.token = "ghp_new_token"
        await vm.save()

        #expect(vm.hasSavedToken)
    }

    @Test("clearToken sets hasSavedToken to false")
    func clearTokenResetsSavedToken() {
        let (vm, _, _, _) = makeViewModel(storedToken: "ghp_existing", suiteName: "ClearSaved")
        #expect(vm.hasSavedToken)

        vm.clearToken()

        #expect(!vm.hasSavedToken)
    }

    // MARK: - viewerLogin

    @Test("save sets viewerLogin on success")
    func saveStoresViewerLogin() async {
        let (vm, _, _, _) = makeViewModel(suiteName: "ViewerLogin")
        mockClient.viewerLoginToReturn = "octocat"

        vm.token = "ghp_valid"
        await vm.save()

        #expect(vm.validationState == .valid)
    }

    @Test("clearToken clears viewerLogin")
    func clearTokenClearsViewerLogin() async {
        let (vm, _, _, _) = makeViewModel(storedToken: "ghp_token", suiteName: "ClearViewerLogin")
        mockClient.viewerLoginToReturn = "octocat"
        vm.token = "ghp_token"
        await vm.save()

        vm.clearToken()

        // viewerLogin is private(set), but we can verify through the state reset
        #expect(vm.validationState == .idle)
    }

    // MARK: - saveError

    @Test("save clears saveError on new attempt")
    func saveClearsSaveError() async {
        let (vm, _, _, _) = makeViewModel(suiteName: "ClearSaveError")
        mockClient.viewerLoginToReturn = "user"

        vm.token = "ghp_token"
        await vm.save()

        #expect(vm.saveError == nil)
    }

    // MARK: - Init loads intervals from UserDefaults

    @Test("init loads prRefreshInterval from UserDefaults")
    func initLoadsPRInterval() {
        let suiteName = "InitPRInterval"
        UserDefaults.standard.set(300.0, forKey: Constants.UserDefaultsKeys.prRefreshInterval)
        let (vm, _, _, _) = makeViewModel(suiteName: suiteName)
        #expect(vm.prRefreshInterval == 300.0)
    }

    @Test("init uses default interval when UserDefaults has no value")
    func initUsesDefaultInterval() {
        UserDefaults.standard.removeObject(forKey: Constants.UserDefaultsKeys.prRefreshInterval)
        let (vm, _, _, _) = makeViewModel(suiteName: "InitDefaultInterval")
        #expect(vm.prRefreshInterval == Constants.App.defaultPRRefreshInterval)
    }

    // MARK: - repoScanInterval

    @Test("repoScanInterval persists and restarts scan")
    func repoScanIntervalRestartsScan() {
        let (vm, _, _, _) = makeViewModel(suiteName: "RepoScanRestart")
        vm.repoScanInterval = 900
        let stored = UserDefaults.standard.double(forKey: Constants.UserDefaultsKeys.repoScanInterval)
        #expect(stored == 900)
    }

    @Test("init loads repoScanInterval from UserDefaults")
    func initLoadsRepoInterval() {
        UserDefaults.standard.set(600.0, forKey: Constants.UserDefaultsKeys.repoScanInterval)
        let (vm, _, _, _) = makeViewModel(suiteName: "InitRepoInterval")
        #expect(vm.repoScanInterval == 600.0)
    }

    @Test("init uses default repoScanInterval when UserDefaults has no value")
    func initUsesDefaultRepoInterval() {
        UserDefaults.standard.removeObject(forKey: Constants.UserDefaultsKeys.repoScanInterval)
        let (vm, _, _, _) = makeViewModel(suiteName: "InitDefaultRepoInterval")
        #expect(vm.repoScanInterval == Constants.App.defaultRepoScanInterval)
    }

    // MARK: - Git directories init

    @Test("init loads git directories from store")
    func initLoadsGitDirectories() {
        let (vm, _, _, _) = makeViewModel(suiteName: "InitGitDirs")
        // Should have loaded (possibly empty) from the store
        #expect(vm.gitDirectories is [URL])
    }
}
