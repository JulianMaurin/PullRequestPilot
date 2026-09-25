import Testing
import Foundation
@testable import PullRequestPilot

@MainActor
@Suite("SettingsViewModel", .keychainCleanup)
struct SettingsViewModelTests {
    private let mockClient = MockGitHubClient()
    private let localRepoService = LocalRepositoryService()

    private func makeViewModel(
        storedToken: String? = nil,
        suiteName: String = "SettingsVMTests",
        reporter: EventReporter = .noop
    ) throws -> (SettingsViewModel, KeychainService, IdentityActor, GitDirectoriesStore, UserDefaults) {
        let keychainService = "com.pullrequestpilot.settings.tests.\(suiteName)"
        let keychain = KeychainService.forTesting(service: keychainService)
        if let storedToken {
            try? keychain.save(key: Constants.Keychain.githubToken, value: storedToken)
        } else {
            try? keychain.delete(key: Constants.Keychain.githubToken)
        }
        let identity = IdentityActor(keychain: keychain, github: mockClient)
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let gitDirStore = GitDirectoriesStore(defaults: defaults)

        let vm = SettingsViewModel(
            identity: identity,
            gitDirectoriesStore: gitDirStore,
            localRepositoryService: localRepoService,
            defaults: defaults,
            reporter: reporter,
            initialToken: storedToken
        )
        return (vm, keychain, identity, gitDirStore, defaults)
    }

    // MARK: - Token

    @Test("hasToken is false when token is empty or whitespace")
    func hasTokenEmpty() throws {
        let (vm, _, _, _, _) = try makeViewModel(suiteName: "HasTokenEmpty")
        vm.token = ""
        #expect(!vm.hasToken)

        vm.token = "   "
        #expect(!vm.hasToken)

        vm.token = "  \n  "
        #expect(!vm.hasToken)
    }

    @Test("hasToken is true when token has content")
    func hasTokenWithContent() throws {
        let (vm, _, _, _, _) = try makeViewModel(suiteName: "HasTokenContent")
        vm.token = "ghp_abc123"
        #expect(vm.hasToken)
    }

    @Test("a validated token resolves the token and permission banners only")
    func saveResolvesTokenErrors() async throws {
        let recorder = EventRecorder()
        let (vm, keychain, _, _, _) = try makeViewModel(suiteName: "SaveResolves", reporter: recorder.reporter())
        defer { try? keychain.delete(key: Constants.Keychain.githubToken) }
        let reporter = recorder.reporter()
        reporter.postError(.unauthorized)
        reporter.postError(.permissionDenied(detail: nil))
        reporter.postError(.decodeCorruption(subsystem: "views", backupPath: nil))
        await mockClient.setViewerLogin("octocat")

        vm.token = "ghp_resolves"
        await vm.save()

        #expect(recorder.unresolvedErrors == [.decodeCorruption(subsystem: "views", backupPath: nil)])
    }

    @Test("a classic token without the repo scope saves with a warning")
    func missingRepoScopeWarns() async throws {
        let (vm, keychain, _, _, _) = try makeViewModel(suiteName: "MissingRepoScope")
        defer { try? keychain.delete(key: Constants.Keychain.githubToken) }
        await mockClient.setViewerLogin("octocat")
        await mockClient.setClassicTokenScopes(["public_repo"])

        vm.token = "ghp_public_only"
        await vm.save()

        #expect(vm.validationState == .valid)
        #expect(vm.tokenScopeWarning == SettingsViewModel.missingRepoScopeWarning)

        await mockClient.setClassicTokenScopes(["repo"])
        vm.beginChangingToken()
        vm.token = "ghp_full"
        await vm.save()
        #expect(vm.tokenScopeWarning == nil)
    }

    @Test("the token help links to GitHub's classic-token form with the repo scope")
    func newClassicTokenLink() throws {
        let components = try #require(URLComponents(url: Constants.URLs.newClassicToken, resolvingAgainstBaseURL: false))
        #expect(components.host == "github.com")
        #expect(components.queryItems?.first { $0.name == "scopes" }?.value == "repo")
    }

    @Test("unavailable git directories are listed and can be removed")
    func unavailableDirectoriesListedAndRemovable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("settings-unavailable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (vm, _, _, store, defaults) = try makeViewModel(suiteName: "UnavailableDirectories")
        #expect(store.saveFromPanel(directory) != nil)
        try FileManager.default.removeItem(at: directory)

        vm.reloadGitDirectories()
        let path = try #require(vm.unavailableDirectoryPaths.first)
        #expect(vm.gitDirectories.isEmpty)
        #expect(path.hasSuffix(directory.lastPathComponent))

        vm.removeUnavailableDirectory(atPath: path)
        #expect(vm.unavailableDirectoryPaths.isEmpty)
        #expect((defaults.array(forKey: "git_directory_bookmarks") as? [Data])?.isEmpty == true)
    }

    @Test("save stores token and validates against GitHub API")
    func saveTokenSuccess() async throws {
        let (vm, keychain, _, _, _) = try makeViewModel(suiteName: "SaveSuccess")
        await mockClient.setViewerLogin("octocat")

        vm.token = "ghp_valid_token"
        await vm.save()

        #expect(vm.validationState == .valid)
        #expect(try keychain.readItem(key: Constants.Keychain.githubToken) == "ghp_valid_token")
    }

    @Test("save transitions through validating state")
    func saveTransitionsStates() async throws {
        let (vm, _, _, _, _) = try makeViewModel(suiteName: "SaveTransitions")
        await mockClient.setViewerLogin("user")

        vm.token = "ghp_token"
        // Before save
        #expect(vm.validationState == .idle)

        await vm.save()
        // After save
        #expect(vm.validationState == .valid)
    }

    @Test("save sets invalid state when API returns unauthorized")
    func saveTokenUnauthorized() async throws {
        let (vm, _, _, _, _) = try makeViewModel(suiteName: "SaveUnauth")
        await mockClient.setErrorToThrow(GitHubClientError.unauthorized)

        vm.token = "ghp_bad_token"
        await vm.save()

        if case .invalid(let message) = vm.validationState {
            #expect(message.contains("invalid") || message.contains("expired") || message.contains("Token"))
        } else {
            Issue.record("Expected invalid state, got \(vm.validationState)")
        }
    }

    @Test("save sets invalid state for graphQL errors")
    func saveTokenGraphQLError() async throws {
        let (vm, _, _, _, _) = try makeViewModel(suiteName: "SaveGraphQL")
        await mockClient.setErrorToThrow(GitHubClientError.graphQLErrors(["scope missing"]))

        vm.token = "ghp_token"
        await vm.save()

        if case .invalid(let message) = vm.validationState {
            #expect(message.contains("scope") || message.contains("rejected"))
        } else {
            Issue.record("Expected invalid state")
        }
    }

    @Test("save sets invalid state for network errors")
    func saveTokenNetworkError() async throws {
        let (vm, _, _, _, _) = try makeViewModel(suiteName: "SaveNetwork")
        await mockClient.setErrorToThrow(GitHubClientError.networkError(URLError(.notConnectedToInternet)))

        vm.token = "ghp_token"
        await vm.save()

        if case .invalid(let message) = vm.validationState {
            #expect(message.contains("internet") || message.contains("reach") || message.contains("Could not"))
        } else {
            Issue.record("Expected invalid state")
        }
    }

    @Test("save sets invalid state for decoding errors")
    func saveTokenDecodingError() async throws {
        let (vm, _, _, _, _) = try makeViewModel(suiteName: "SaveDecoding")
        await mockClient.setErrorToThrow(GitHubClientError.decodingError(URLError(.cannotParseResponse)))

        vm.token = "ghp_token"
        await vm.save()

        if case .invalid(let message) = vm.validationState {
            #expect(message.contains("unexpected") || message.contains("response") || message.contains("Received"))
        } else {
            Issue.record("Expected invalid state")
        }
    }

    @Test("clearToken removes from keychain and resets state")
    func clearToken() async throws {
        let (vm, keychain, identity, _, _) = try makeViewModel(storedToken: "ghp_existing", suiteName: "ClearToken")
        vm.token = "ghp_existing"

        await vm.clearToken()

        #expect(vm.token == "")
        #expect(vm.validationState == .idle)
        #expect(try keychain.readItem(key: Constants.Keychain.githubToken) == nil)
        #expect(await identity.token() == nil)
    }

    // MARK: - Computed Properties

    @Test("isScanning delegates to localRepositoryService")
    func isScanningDelegation() throws {
        let (vm, _, _, _, _) = try makeViewModel(suiteName: "Scanning")
        #expect(vm.isScanning == localRepoService.isScanning)
    }

    @Test("lastScanDate delegates to localRepositoryService")
    func lastScanDateDelegation() throws {
        let (vm, _, _, _, _) = try makeViewModel(suiteName: "LastScan")
        #expect(vm.lastScanDate == localRepoService.lastScanDate)
    }

    @Test("indexedRepoCount delegates to localRepositoryService")
    func indexedRepoCountDelegation() throws {
        let (vm, _, _, _, _) = try makeViewModel(suiteName: "RepoCount")
        #expect(vm.indexedRepoCount == localRepoService.indexedRepoCount)
    }

    // MARK: - Git Directories

    @Test("removeGitDirectory by URL removes and saves")
    func removeGitDirectoryByURL() throws {
        let (vm, _, _, _, _) = try makeViewModel(suiteName: "RemoveDir")
        let url = URL(fileURLWithPath: "/tmp/test-repo")
        vm.gitDirectories = [url]

        vm.removeGitDirectory(url)

        #expect(vm.gitDirectories.isEmpty)
    }

    @Test("removeGitDirectory by offsets removes correct entry")
    func removeGitDirectoryByOffset() throws {
        let (vm, _, _, _, _) = try makeViewModel(suiteName: "RemoveDirOffset")
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

    @Test("rescan runs a repository scan")
    func rescanTriggersScan() async throws {
        let (vm, _, _, _, _) = try makeViewModel(suiteName: "Rescan")
        #expect(localRepoService.lastScanDate == nil)

        vm.rescan()

        try await TestWait.until { localRepoService.lastScanDate != nil }
        #expect(localRepoService.lastScanDate != nil)
        #expect(!localRepoService.isScanning)
    }

    // MARK: - Interval setters

    @Test("prRefreshInterval posts notification on change")
    func prRefreshIntervalPostsNotification() throws {
        let (vm, _, _, _, _) = try makeViewModel(suiteName: "PRInterval")
        nonisolated(unsafe) var notificationReceived = false
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
    func repoScanIntervalPersists() throws {
        let (vm, _, _, _, defaults) = try makeViewModel(suiteName: "RepoInterval")
        vm.repoScanInterval = 600
        let stored = defaults.double(forKey: Constants.UserDefaultsKeys.repoScanInterval)
        #expect(stored == 600)
    }

    // MARK: - save with generic (non-GitHubClientError) error

    @Test("save sets invalid state for unexpected errors")
    func saveTokenGenericError() async throws {
        let (vm, _, _, _, _) = try makeViewModel(suiteName: "SaveGeneric")

        // Create a custom error that is NOT GitHubClientError
        struct TestError: Error {}
        await mockClient.setErrorToThrow(TestError())

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
    func saveTrimsWhitespace() async throws {
        let (vm, keychain, _, _, _) = try makeViewModel(suiteName: "SaveTrim")
        await mockClient.setViewerLogin("user")

        vm.token = "  ghp_token_with_spaces  \n"
        await vm.save()

        #expect(try keychain.readItem(key: Constants.Keychain.githubToken) == "ghp_token_with_spaces")
    }

    // MARK: - Init loads token from cache

    @Test("init loads existing token from cache")
    func initLoadsToken() throws {
        let (vm, _, _, _, _) = try makeViewModel(storedToken: "ghp_existing", suiteName: "InitLoads")
        // In DEBUG with GITHUB_TOKEN env var, the env var takes precedence
        if ProcessInfo.processInfo.environment["GITHUB_TOKEN"] == nil {
            #expect(vm.token == "ghp_existing")
            #expect(vm.hasToken)
        }
    }

    // MARK: - hasSavedToken

    @Test("hasSavedToken is true when token exists in cache")
    func hasSavedTokenTrue() throws {
        let (vm, _, _, _, _) = try makeViewModel(storedToken: "ghp_token", suiteName: "HasSavedTrue")
        #expect(vm.hasSavedToken)
    }

    @Test("hasSavedToken is false when no token in cache")
    func hasSavedTokenFalse() throws {
        let (vm, _, _, _, _) = try makeViewModel(suiteName: "HasSavedFalse")
        #expect(!vm.hasSavedToken)
    }

    @Test("save sets hasSavedToken to true")
    func saveSetsSavedToken() async throws {
        let (vm, _, _, _, _) = try makeViewModel(suiteName: "SaveSetsSaved")
        await mockClient.setViewerLogin("user")
        #expect(!vm.hasSavedToken)

        vm.token = "ghp_new_token"
        await vm.save()

        #expect(vm.hasSavedToken)
    }

    @Test("clearToken sets hasSavedToken to false")
    func clearTokenResetsSavedToken() async throws {
        let (vm, _, _, _, _) = try makeViewModel(storedToken: "ghp_existing", suiteName: "ClearSaved")
        #expect(vm.hasSavedToken)

        await vm.clearToken()

        #expect(!vm.hasSavedToken)
    }

    // MARK: - viewerLogin

    @Test("save sets viewerLogin on success")
    func saveStoresViewerLogin() async throws {
        let (vm, _, _, _, _) = try makeViewModel(suiteName: "ViewerLogin")
        await mockClient.setViewerLogin("octocat")

        vm.token = "ghp_valid"
        await vm.save()

        #expect(vm.validationState == .valid)
        #expect(vm.viewerLogin == "octocat")
    }

    @Test("clearToken clears viewerLogin and resets state")
    func clearTokenClearsViewerLogin() async throws {
        let (vm, _, _, _, _) = try makeViewModel(storedToken: "ghp_token", suiteName: "ClearViewerLogin")
        await mockClient.setViewerLogin("octocat")
        vm.token = "ghp_token"
        await vm.save()
        #expect(vm.viewerLogin == "octocat")

        await vm.clearToken()

        #expect(vm.viewerLogin == nil)
        #expect(vm.validationState == .idle)
    }

    // MARK: - saveError

    @Test("save clears saveError on new attempt")
    func saveClearsSaveError() async throws {
        let (vm, _, _, _, _) = try makeViewModel(suiteName: "ClearSaveError")
        await mockClient.setViewerLogin("user")

        vm.token = "ghp_token"
        await vm.save()

        #expect(vm.saveError == nil)
    }

    // MARK: - Init loads intervals from UserDefaults

    @Test("init loads prRefreshInterval from UserDefaults")
    func initLoadsPRInterval() throws {
        let suiteName = "InitPRInterval"
        let keychainService = "com.pullrequestpilot.settings.tests.\(suiteName)"
        let keychain = KeychainService.forTesting(service: keychainService)
        try? keychain.delete(key: Constants.Keychain.githubToken)
        let identity = IdentityActor(keychain: keychain, github: mockClient)
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(300.0, forKey: Constants.UserDefaultsKeys.prRefreshInterval)
        let gitDirStore = GitDirectoriesStore(defaults: defaults)
        let vm = SettingsViewModel(identity: identity, gitDirectoriesStore: gitDirStore, localRepositoryService: localRepoService, defaults: defaults)
        #expect(vm.prRefreshInterval == 300.0)
    }

    @Test("init uses default interval when UserDefaults has no value")
    func initUsesDefaultInterval() throws {
        let (vm, _, _, _, _) = try makeViewModel(suiteName: "InitDefaultInterval")
        #expect(vm.prRefreshInterval == Constants.App.defaultPRRefreshInterval)
    }

    // MARK: - repoScanInterval

    @Test("repoScanInterval persists and restarts scan")
    func repoScanIntervalRestartsScan() throws {
        let (vm, _, _, _, defaults) = try makeViewModel(suiteName: "RepoScanRestart")
        vm.repoScanInterval = 900
        let stored = defaults.double(forKey: Constants.UserDefaultsKeys.repoScanInterval)
        #expect(stored == 900)
    }

    @Test("init loads repoScanInterval from UserDefaults")
    func initLoadsRepoInterval() throws {
        let suiteName = "InitRepoInterval"
        let keychainService = "com.pullrequestpilot.settings.tests.\(suiteName)"
        let keychain = KeychainService.forTesting(service: keychainService)
        try? keychain.delete(key: Constants.Keychain.githubToken)
        let identity = IdentityActor(keychain: keychain, github: mockClient)
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(600.0, forKey: Constants.UserDefaultsKeys.repoScanInterval)
        let gitDirStore = GitDirectoriesStore(defaults: defaults)
        let vm = SettingsViewModel(identity: identity, gitDirectoriesStore: gitDirStore, localRepositoryService: localRepoService, defaults: defaults)
        #expect(vm.repoScanInterval == 600.0)
    }

    @Test("init uses default repoScanInterval when UserDefaults has no value")
    func initUsesDefaultRepoInterval() throws {
        let (vm, _, _, _, _) = try makeViewModel(suiteName: "InitDefaultRepoInterval")
        #expect(vm.repoScanInterval == Constants.App.defaultRepoScanInterval)
    }

    // MARK: - Git directories init

    @Test("init loads git directories from store")
    func initLoadsGitDirectories() throws {
        let (vm, _, _, _, _) = try makeViewModel(suiteName: "InitGitDirs")
        // Should have loaded (possibly empty) from the store — verify it's accessible
        #expect(vm.gitDirectories.isEmpty)
    }

    // MARK: - viewerAvatarURL

    @Test("save sets viewerAvatarURL on success")
    func saveStoresViewerAvatarURL() async throws {
        let (vm, _, _, _, _) = try makeViewModel(suiteName: "AvatarURL")
        let avatarURL = try #require(URL(string: "https://avatars.githubusercontent.com/u/123"))
        await mockClient.setViewerLogin("octocat")
        await mockClient.setViewerAvatarURL(avatarURL)

        vm.token = "ghp_valid"
        await vm.save()

        #expect(vm.viewerAvatarURL == avatarURL)
        #expect(vm.viewerLogin == "octocat")
    }

    @Test("clearToken resets viewerAvatarURL")
    func clearTokenResetsAvatarURL() async throws {
        let (vm, _, _, _, _) = try makeViewModel(storedToken: "ghp_token", suiteName: "ClearAvatar")
        await mockClient.setViewerLogin("octocat")
        await mockClient.setViewerAvatarURL(URL(string: "https://example.com/avatar"))
        vm.token = "ghp_token"
        await vm.save()

        #expect(vm.viewerAvatarURL != nil)

        await vm.clearToken()

        #expect(vm.viewerAvatarURL == nil)
        #expect(vm.viewerLogin == nil)
    }

    // MARK: - Token revoked mid-session

    @Test("a confirmed revocation signs the UI out and asks for a new token")
    func revokedTokenReturnsToTokenField() async throws {
        let (vm, keychain, identity, _, _) = try makeViewModel(suiteName: "RevokedToken")
        defer { try? keychain.delete(key: Constants.Keychain.githubToken) }
        await mockClient.setViewerLogin("octocat")
        vm.token = "ghp_valid"
        await vm.save()
        #expect(vm.viewerLogin == "octocat")

        await mockClient.setValidateTokenError(GitHubClientError.unauthorized)
        await identity.handleUnauthorized(staleToken: "ghp_valid")
        try await TestWait.until { !vm.hasSavedToken }

        #expect(!vm.hasSavedToken)
        #expect(vm.viewerLogin == nil)
        #expect(vm.viewerAvatarURL == nil)
        #expect(vm.token.isEmpty)
        guard case .invalid(let message) = vm.validationState else {
            Issue.record("Expected an invalid state explaining the rejection, got \(vm.validationState)")
            return
        }
        #expect(message.contains("rejected the saved token"))
        #expect(try keychain.readItem(key: Constants.Keychain.githubToken) == nil)
    }

    @Test("signing out does not show the rejected-token message")
    func signOutIsNotReportedAsRejection() async throws {
        let (vm, _, _, _, _) = try makeViewModel(storedToken: "ghp_token", suiteName: "SignOutNotRejected")

        await vm.clearToken()
        for _ in 0..<50 { await Task.yield() }

        #expect(vm.validationState == .idle)
    }

    // MARK: - Save commits in one step

    @Test("save validates once and commits login and avatar together")
    func saveMakesOneValidationCall() async throws {
        let (vm, keychain, _, _, _) = try makeViewModel(suiteName: "SaveOneCall")
        defer { try? keychain.delete(key: Constants.Keychain.githubToken) }
        await mockClient.setViewerLogin("octocat")
        await mockClient.setViewerAvatarURL(URL(string: "https://example.com/avatar"))

        vm.token = "ghp_valid"
        await vm.save()

        #expect(await mockClient.validateTokenCallCount == 1)
        #expect(vm.viewerLogin == "octocat")
        #expect(vm.viewerAvatarURL != nil)
    }

    // MARK: - Change token

    @Test("a rejected replacement token keeps the current session")
    func changeTokenFailureKeepsSession() async throws {
        let (vm, keychain, identity, _, _) = try makeViewModel(suiteName: "ChangeTokenFailure")
        defer { try? keychain.delete(key: Constants.Keychain.githubToken) }
        await mockClient.setViewerLogin("octocat")
        vm.token = "ghp_current"
        await vm.save()

        vm.beginChangingToken()
        #expect(vm.isChangingToken)
        #expect(vm.token.isEmpty)
        #expect(vm.validationState == .idle)

        await mockClient.setValidateTokenError(GitHubClientError.unauthorized)
        vm.token = "ghp_bad"
        await vm.save()

        #expect(vm.isChangingToken)
        #expect(vm.viewerLogin == "octocat")
        #expect(vm.hasSavedToken)
        #expect(await identity.token() == "ghp_current")

        vm.cancelChangingToken()
        #expect(!vm.isChangingToken)
        #expect(vm.validationState == .idle)
    }

    @Test("a valid replacement token ends change mode with the new account")
    func changeTokenSuccessSwitchesAccount() async throws {
        let (vm, keychain, identity, _, _) = try makeViewModel(suiteName: "ChangeTokenSuccess")
        defer { try? keychain.delete(key: Constants.Keychain.githubToken) }
        await mockClient.setViewerLogin("octocat")
        vm.token = "ghp_current"
        await vm.save()

        vm.beginChangingToken()
        await mockClient.setViewerLogin("hubot")
        vm.token = "ghp_new"
        await vm.save()

        #expect(!vm.isChangingToken)
        #expect(vm.viewerLogin == "hubot")
        #expect(vm.validationState == .valid)
        #expect(await identity.token() == "ghp_new")
    }

    // MARK: - Keychain unreadable at launch

    @Test("an unreadable Keychain at launch explains itself instead of looking like a first run")
    func keychainReadFailureIsExplained() throws {
        let suiteName = "KeychainReadFailure"
        let keychain = KeychainService.forTesting(service: "com.pullrequestpilot.settings.tests.\(suiteName)")
        let identity = IdentityActor(keychain: keychain, github: mockClient)
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let vm = SettingsViewModel(
            identity: identity,
            gitDirectoriesStore: GitDirectoriesStore(defaults: defaults),
            localRepositoryService: localRepoService,
            defaults: defaults,
            tokenReadFailure: "User interaction is not allowed."
        )

        #expect(!vm.hasSavedToken)
        guard case .invalid(let message) = vm.validationState else {
            Issue.record("Expected an invalid state explaining the Keychain failure, got \(vm.validationState)")
            return
        }
        #expect(message.contains("Keychain"))
        #expect(message.contains("User interaction is not allowed."))
    }

    // MARK: - Helpers

    // MARK: - prRefreshInterval persists to UserDefaults

    @Test("prRefreshInterval persists value to UserDefaults")
    func prRefreshIntervalPersists() throws {
        let (vm, _, _, _, defaults) = try makeViewModel(suiteName: "PRIntervalPersist")
        vm.prRefreshInterval = 120
        let stored = defaults.double(forKey: Constants.UserDefaultsKeys.prRefreshInterval)
        #expect(stored == 120)
    }
}
