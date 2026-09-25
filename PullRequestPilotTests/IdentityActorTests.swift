import Testing
import Foundation
import Security
@testable import PullRequestPilot

@Suite("IdentityActor")
struct IdentityActorTests {

    private func makeIdentity(keychainSuite: String = UUID().uuidString, github: GitHubClientProtocol = MockGitHubClient())
        -> (IdentityActor, KeychainService)
    {
        let keychain = KeychainService(service: "com.pullrequestpilot.identity.tests.\(keychainSuite)")
        try? keychain.delete(key: Constants.Keychain.githubToken)
        return (IdentityActor(keychain: keychain, github: github), keychain)
    }

    // MARK: - Launch state

    @Test("init without a stored token starts unauthenticated")
    func initWithoutStoredToken() async {
        let (identity, _) = makeIdentity()
        #expect(await identity.state == .unauthenticated)
    }

    @Test("init with a stored token starts authenticated, viewer login not yet fetched")
    func initWithStoredToken() async {
        let identity = IdentityActor(
            keychain: KeychainService(service: "com.pullrequestpilot.identity.tests.init-stored"),
            github: MockGitHubClient(),
            storedToken: "ghp_stored"
        )
        #expect(await identity.state == .authenticated(token: "ghp_stored", viewerLogin: nil))
    }

    @Test("readStoredToken returns the Keychain token",
          .enabled(if: ProcessInfo.processInfo.environment["GITHUB_TOKEN"] == nil))
    func readStoredTokenFromKeychain() throws {
        let (_, keychain) = makeIdentity(keychainSuite: "read-stored")
        try keychain.save(key: Constants.Keychain.githubToken, value: "ghp_from_keychain")
        defer { try? keychain.delete(key: Constants.Keychain.githubToken) }

        #expect(try IdentityActor.readStoredToken(from: keychain) == "ghp_from_keychain")
    }

    @Test("readStoredToken returns nil when nothing is saved",
          .enabled(if: ProcessInfo.processInfo.environment["GITHUB_TOKEN"] == nil))
    func readStoredTokenMissing() throws {
        let (_, keychain) = makeIdentity()
        #expect(try IdentityActor.readStoredToken(from: keychain) == nil)
    }

    @Test("readStoredToken throws when the Keychain is unreadable",
          .enabled(if: ProcessInfo.processInfo.environment["GITHUB_TOKEN"] == nil))
    func readStoredTokenKeychainFailure() {
        let keychain = KeychainService(
            service: "com.pullrequestpilot.identity.tests.locked",
            secItemCopyMatching: { _, _ in errSecInteractionNotAllowed }
        )
        #expect(throws: KeychainError.unexpectedStatus(errSecInteractionNotAllowed)) {
            try IdentityActor.readStoredToken(from: keychain)
        }
    }

    // MARK: - Swap happy path

    @Test("swap with valid token transitions to authenticated and returns the viewer")
    func swapHappyPath() async throws {
        let mock = MockGitHubClient()
        let avatarURL = try #require(URL(string: "https://avatars.githubusercontent.com/u/1"))
        await mock.setViewerLogin("octocat")
        await mock.setViewerAvatarURL(avatarURL)
        let (identity, keychain) = makeIdentity(keychainSuite: "swap-happy", github: mock)

        let viewer = try await identity.swap(to: "ghp_valid")

        #expect(viewer.login == "octocat")
        #expect(viewer.avatarURL == avatarURL)
        let state = await identity.state
        #expect(state == .authenticated(token: "ghp_valid", viewerLogin: "octocat"))
        #expect(try keychain.readItem(key: Constants.Keychain.githubToken) == "ghp_valid")
        #expect(await mock.validateTokenCallCount == 1)
    }

    @Test("swap trims whitespace before validating and saving")
    func swapTrimsWhitespace() async throws {
        let mock = MockGitHubClient()
        await mock.setViewerLogin("octocat")
        let (identity, keychain) = makeIdentity(keychainSuite: "swap-trim", github: mock)

        _ = try await identity.swap(to: "  ghp_padded  \n")

        #expect(try keychain.readItem(key: Constants.Keychain.githubToken) == "ghp_padded")
        #expect(await mock.receivedValidateTokens.last == "ghp_padded")
    }

    // MARK: - Swap failure: prior state preserved

    @Test("swap with invalid token throws .invalidToken and does NOT write Keychain")
    func swapInvalidTokenPreservesKeychain() async throws {
        let mock = MockGitHubClient()
        await mock.setValidateTokenError(GitHubClientError.unauthorized)
        let (identity, keychain) = makeIdentity(keychainSuite: "swap-invalid", github: mock)

        do {
            _ = try await identity.swap(to: "ghp_bad")
            Issue.record("Expected swap to throw")
        } catch let error as AuthError {
            #expect(error.reason == .invalidToken)
        }

        let state = await identity.state
        #expect(state == .unauthenticated)
        #expect(try keychain.readItem(key: Constants.Keychain.githubToken) == nil)
    }

    @Test("swap failure after prior authentication keeps the old token active")
    func swapFailurePreservesPriorAuth() async throws {
        let mock = MockGitHubClient()
        await mock.setViewerLogin("alice")
        let (identity, keychain) = makeIdentity(keychainSuite: "swap-preserve", github: mock)

        _ = try await identity.swap(to: "ghp_good")
        #expect(try keychain.readItem(key: Constants.Keychain.githubToken) == "ghp_good")

        // Now attempt a bad token
        await mock.setValidateTokenError(GitHubClientError.unauthorized)
        do {
            _ = try await identity.swap(to: "ghp_bad")
            Issue.record("Expected swap to throw")
        } catch is AuthError {
            // expected
        }

        // Prior token is still the committed identity
        let state = await identity.state
        #expect(state == .authenticated(token: "ghp_good", viewerLogin: "alice"))
        #expect(try keychain.readItem(key: Constants.Keychain.githubToken) == "ghp_good")
    }

    // MARK: - Cancellation

    @Test("swap rethrows CancellationError without mutating state")
    func swapCancellationPreservesState() async throws {
        let mock = MockGitHubClient()
        await mock.setViewerLogin("alice")
        let (identity, keychain) = makeIdentity(keychainSuite: "swap-cancel", github: mock)

        _ = try await identity.swap(to: "ghp_good")

        await mock.setValidateTokenError(CancellationError())
        do {
            _ = try await identity.swap(to: "ghp_cancelled")
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // expected
        }

        let state = await identity.state
        #expect(state == .authenticated(token: "ghp_good", viewerLogin: "alice"))
        #expect(try keychain.readItem(key: Constants.Keychain.githubToken) == "ghp_good")
    }

    @Test("swap maps URLError.cancelled to CancellationError")
    func swapURLErrorCancelled() async {
        let mock = MockGitHubClient()
        await mock.setValidateTokenError(URLError(.cancelled))
        let (identity, _) = makeIdentity(keychainSuite: "swap-urlcancel", github: mock)

        do {
            _ = try await identity.swap(to: "ghp_x")
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    // MARK: - Invalidate

    @Test("invalidate transitions to unauthenticated and clears Keychain")
    func invalidateClears() async throws {
        let mock = MockGitHubClient()
        await mock.setViewerLogin("alice")
        let (identity, keychain) = makeIdentity(keychainSuite: "invalidate-clear", github: mock)

        _ = try await identity.swap(to: "ghp_x")
        #expect(try keychain.readItem(key: Constants.Keychain.githubToken) == "ghp_x")

        await identity.invalidate(reason: .unauthorized)

        let state = await identity.state
        #expect(state == .unauthenticated)
        #expect(try keychain.readItem(key: Constants.Keychain.githubToken) == nil)
    }

    @Test("invalidateIfMatchingToken does nothing when token differs")
    func invalidateIfMatchingSkipsWhenDifferent() async throws {
        let mock = MockGitHubClient()
        await mock.setViewerLogin("alice")
        let (identity, keychain) = makeIdentity(keychainSuite: "invalidate-nonmatch", github: mock)

        _ = try await identity.swap(to: "ghp_fresh")

        let invalidated = await identity.invalidateIfMatchingToken("ghp_stale", reason: .unauthorized)
        #expect(!invalidated)

        // Fresh token still active — regression for "stale 401 nuking fresh token".
        let state = await identity.state
        #expect(state.token == "ghp_fresh")
        #expect(try keychain.readItem(key: Constants.Keychain.githubToken) == "ghp_fresh")
    }

    @Test("invalidateIfMatchingToken clears when token matches current state")
    func invalidateIfMatchingClearsWhenEqual() async throws {
        let mock = MockGitHubClient()
        await mock.setViewerLogin("alice")
        let (identity, _) = makeIdentity(keychainSuite: "invalidate-match", github: mock)

        _ = try await identity.swap(to: "ghp_same")

        let invalidated = await identity.invalidateIfMatchingToken("ghp_same", reason: .unauthorized)
        #expect(invalidated)
        let state = await identity.state
        #expect(state == .unauthenticated)
    }

    // MARK: - 401 revalidation

    @Test("a 401 whose revalidation succeeds keeps identity and Keychain")
    func transient401KeepsToken() async throws {
        let mock = MockGitHubClient()
        await mock.setViewerLogin("alice")
        let (identity, keychain) = makeIdentity(keychainSuite: "reval-transient", github: mock)

        _ = try await identity.swap(to: "ghp_valid")
        await identity.handleUnauthorized(staleToken: "ghp_valid")

        let state = await identity.state
        #expect(state.token == "ghp_valid")
        #expect(try keychain.readItem(key: Constants.Keychain.githubToken) == "ghp_valid")
        // swap + revalidation
        #expect(await mock.validateTokenCallCount == 2)
        try? keychain.delete(key: Constants.Keychain.githubToken)
    }

    @Test("a 401 whose revalidation confirms unauthorized invalidates and clears Keychain")
    func confirmed401Invalidates() async throws {
        let mock = MockGitHubClient()
        await mock.setViewerLogin("alice")
        let (identity, keychain) = makeIdentity(keychainSuite: "reval-confirmed", github: mock)

        _ = try await identity.swap(to: "ghp_revoked")
        await mock.setValidateTokenError(GitHubClientError.unauthorized)
        await identity.handleUnauthorized(staleToken: "ghp_revoked")

        let state = await identity.state
        #expect(state == .unauthenticated)
        #expect(try keychain.readItem(key: Constants.Keychain.githubToken) == nil)
    }

    @Test("a 401 whose revalidation fails with a network error keeps the token")
    func inconclusive401KeepsToken() async throws {
        let mock = MockGitHubClient()
        await mock.setViewerLogin("alice")
        let (identity, keychain) = makeIdentity(keychainSuite: "reval-network", github: mock)

        _ = try await identity.swap(to: "ghp_offline")
        await mock.setValidateTokenError(GitHubClientError.networkError(URLError(.notConnectedToInternet)))
        await identity.handleUnauthorized(staleToken: "ghp_offline")

        let state = await identity.state
        #expect(state.token == "ghp_offline")
        #expect(try keychain.readItem(key: Constants.Keychain.githubToken) == "ghp_offline")
        try? keychain.delete(key: Constants.Keychain.githubToken)
    }

    @Test("handleUnauthorized for a superseded token is a no-op")
    func handleUnauthorizedSupersededTokenNoOp() async throws {
        let mock = MockGitHubClient()
        await mock.setViewerLogin("alice")
        let (identity, keychain) = makeIdentity(keychainSuite: "reval-superseded", github: mock)

        _ = try await identity.swap(to: "ghp_fresh")
        await identity.handleUnauthorized(staleToken: "ghp_old")

        let state = await identity.state
        #expect(state.token == "ghp_fresh")
        // Only the swap validated — no revalidation ran for the stale token.
        #expect(await mock.validateTokenCallCount == 1)
        try? keychain.delete(key: Constants.Keychain.githubToken)
    }

    // MARK: - Concurrent swaps

    @Test("concurrent swaps serialize; last committed wins")
    func concurrentSwapsSerialize() async throws {
        let mock = MockGitHubClient()
        await mock.setViewerLogin("user")
        let (identity, _) = makeIdentity(keychainSuite: "concurrent-swap", github: mock)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await identity.swap(to: "ghp_A") }
            group.addTask { _ = try? await identity.swap(to: "ghp_B") }
            group.addTask { _ = try? await identity.swap(to: "ghp_C") }
        }

        // Whichever ran last is the committed token; all three are candidates.
        let finalToken = await identity.token()
        #expect(finalToken == "ghp_A" || finalToken == "ghp_B" || finalToken == "ghp_C")

        // Every swap went through validation
        #expect(await mock.validateTokenCallCount == 3)
    }

    // MARK: - currentViewerLogin

    @Test("currentViewerLogin returns nil when unauthenticated")
    func currentViewerLoginUnauth() async throws {
        let (identity, _) = makeIdentity()
        let login = try await identity.currentViewerLogin()
        #expect(login == nil)
    }

    @Test("currentViewerLogin returns cached login without refetch")
    func currentViewerLoginCached() async throws {
        let mock = MockGitHubClient()
        await mock.setViewerLogin("alice")
        let (identity, _) = makeIdentity(keychainSuite: "viewer-cached", github: mock)

        _ = try await identity.swap(to: "ghp_x")
        let callsAfterSwap = await mock.validateTokenCallCount

        let login = try await identity.currentViewerLogin()
        #expect(login == "alice")
        #expect(await mock.validateTokenCallCount == callsAfterSwap)
    }

    // MARK: - currentViewerLogin lazy fetch (launch path: stored token, no login yet)

    private func makeLaunchedIdentity(github: GitHubClientProtocol, storedToken: String = "ghp_stored")
        -> (IdentityActor, KeychainService)
    {
        let keychain = KeychainService(service: "com.pullrequestpilot.identity.tests.launched.\(UUID().uuidString)")
        return (IdentityActor(keychain: keychain, github: github, storedToken: storedToken), keychain)
    }

    @Test("currentViewerLogin fetches the login once and caches it")
    func lazyLoginFetchedOnceAndCached() async throws {
        let mock = MockGitHubClient()
        await mock.setViewerLogin("alice")
        let (identity, _) = makeLaunchedIdentity(github: mock)

        #expect(try await identity.currentViewerLogin() == "alice")
        #expect(try await identity.currentViewerLogin() == "alice")

        #expect(await mock.validateTokenCallCount == 1)
        #expect(await mock.receivedValidateTokens == ["ghp_stored"])
        #expect(await identity.state == .authenticated(token: "ghp_stored", viewerLogin: "alice"))
    }

    @Test("currentViewerLogin rethrows cancellation, including URLError.cancelled")
    func lazyLoginRethrowsCancellation() async {
        for cancellation: any Error in [CancellationError(), URLError(.cancelled)] {
            let mock = MockGitHubClient()
            await mock.setValidateTokenError(cancellation)
            let (identity, _) = makeLaunchedIdentity(github: mock)

            await #expect(throws: CancellationError.self) {
                _ = try await identity.currentViewerLogin()
            }
            #expect(await identity.state == .authenticated(token: "ghp_stored", viewerLogin: nil))
        }
    }

    @Test("currentViewerLogin failure returns nil without caching; the next call retries")
    func lazyLoginFailureIsNotLatched() async throws {
        let mock = MockGitHubClient()
        await mock.setValidateTokenError(GitHubClientError.networkError(URLError(.notConnectedToInternet)))
        let (identity, _) = makeLaunchedIdentity(github: mock)

        #expect(try await identity.currentViewerLogin() == nil)

        await mock.setValidateTokenError(nil)
        await mock.setViewerLogin("bob")
        #expect(try await identity.currentViewerLogin() == "bob")
        #expect(await mock.validateTokenCallCount == 2)
    }

    @Test("concurrent currentViewerLogin calls share one fetch")
    func lazyLoginConcurrentCallsJoin() async throws {
        let client = GatedValidationClient(gatedToken: "ghp_stored", gatedOutcome: .success("alice"))
        let watchdog = Self.gateWatchdog(for: client)
        defer { watchdog.cancel() }
        let (identity, _) = makeLaunchedIdentity(github: client)

        async let first = identity.currentViewerLogin()
        async let second = identity.currentViewerLogin()
        async let third = identity.currentViewerLogin()
        try await client.waitForPendingValidations(1)
        await Self.yieldToOtherTasks()
        await client.releaseAll()

        let logins = try await [first, second, third]
        #expect(logins == ["alice", "alice", "alice"])
        #expect(await client.validateTokenCallCount == 1)
    }

    @Test("a swap during an in-flight login fetch keeps the stale login out of the cache")
    func lazyLoginDiscardedAfterSwap() async throws {
        let client = GatedValidationClient(gatedToken: "ghp_stored", gatedOutcome: .success("alice"))
        let watchdog = Self.gateWatchdog(for: client)
        defer { watchdog.cancel() }
        let (identity, keychain) = makeLaunchedIdentity(github: client)

        async let staleLogin = identity.currentViewerLogin()
        try await client.waitForPendingValidations(1)
        let viewer = try await identity.swap(to: "ghp_new")
        try keychain.delete(key: Constants.Keychain.githubToken)
        await client.releaseAll()
        _ = try await staleLogin

        #expect(viewer.login == GatedValidationClient.ungatedLogin)
        #expect(await identity.state == .authenticated(token: "ghp_new", viewerLogin: GatedValidationClient.ungatedLogin))
    }

    // MARK: - 401 revalidation coalescing and re-arm

    @Test("a later 401 revalidates again after an earlier one found the token valid")
    func revalidationReArmsAfterCompletion() async throws {
        let mock = MockGitHubClient()
        await mock.setViewerLogin("alice")
        let (identity, keychain) = makeIdentity(keychainSuite: "reval-rearm", github: mock)
        _ = try await identity.swap(to: "ghp_valid")

        await identity.handleUnauthorized(staleToken: "ghp_valid")
        #expect(await identity.state.token == "ghp_valid")

        await mock.setValidateTokenError(GitHubClientError.unauthorized)
        await identity.handleUnauthorized(staleToken: "ghp_valid")

        #expect(await identity.state == .unauthenticated)
        #expect(try keychain.readItem(key: Constants.Keychain.githubToken) == nil)
        // swap + two revalidations
        #expect(await mock.validateTokenCallCount == 3)
    }

    @Test("concurrent 401s share one revalidation round-trip")
    func concurrentUnauthorizedCoalesces() async throws {
        let client = GatedValidationClient(gatedToken: "ghp_stored", gatedOutcome: .failure(.unauthorized))
        let watchdog = Self.gateWatchdog(for: client)
        defer { watchdog.cancel() }
        let (identity, _) = makeLaunchedIdentity(github: client)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { await identity.handleUnauthorized(staleToken: "ghp_stored") }
            }
            group.addTask {
                try? await client.waitForPendingValidations(1)
                await Self.yieldToOtherTasks()
                await client.releaseAll()
            }
        }

        #expect(await identity.state == .unauthenticated)
        #expect(await client.validateTokenCallCount == 1)
    }

    // MARK: - Invalidation stream

    @Test("invalidate publishes its reason", .timeLimit(.minutes(1)))
    func invalidatePublishesReason() async {
        let (identity, _) = makeIdentity()
        var reasons = identity.invalidations.makeAsyncIterator()

        await identity.invalidate(reason: .userSignedOut)

        #expect(await reasons.next() == .userSignedOut)
    }

    @Test("a confirmed 401 publishes .unauthorized", .timeLimit(.minutes(1)))
    func confirmed401PublishesUnauthorized() async throws {
        let mock = MockGitHubClient()
        await mock.setViewerLogin("alice")
        let (identity, _) = makeIdentity(keychainSuite: "reval-publish", github: mock)
        var reasons = identity.invalidations.makeAsyncIterator()
        _ = try await identity.swap(to: "ghp_revoked")

        await mock.setValidateTokenError(GitHubClientError.unauthorized)
        await identity.handleUnauthorized(staleToken: "ghp_revoked")

        #expect(await reasons.next() == .unauthorized)
    }

    // MARK: - Helpers

    /// Lets tasks that are already runnable reach their next suspension point
    /// before a gate opens. Never needed for correctness: a late joiner finds
    /// the cached or invalidated state and makes no extra call.
    private static func yieldToOtherTasks() async {
        for _ in 0..<50 { await Task.yield() }
    }

    /// Drains the gate if a test misses an interleaving, so the trailing
    /// awaits resolve and the failed expectation is reported instead of a hang.
    private static func gateWatchdog(for client: GatedValidationClient) -> Task<Void, any Error> {
        Task {
            try await Task.sleep(for: .seconds(20))
            await client.releaseAll()
        }
    }
}

// MARK: - GatedValidationClient

/// Parks `validateToken` calls for `gatedToken` until the test releases them,
/// so concurrent callers can be observed joining an in-flight request. Other
/// tokens validate immediately as `ungatedLogin`.
private actor GatedValidationClient: GitHubClientProtocol {
    static let ungatedLogin = "carol"

    private let gatedToken: String
    private let gatedOutcome: Result<String, GitHubClientError>
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false
    private(set) var validateTokenCallCount = 0

    init(gatedToken: String, gatedOutcome: Result<String, GitHubClientError>) {
        self.gatedToken = gatedToken
        self.gatedOutcome = gatedOutcome
    }

    func validateToken(_ token: String) async throws -> (login: String, avatarURL: URL?) {
        validateTokenCallCount += 1
        guard token == gatedToken else { return (login: Self.ungatedLogin, avatarURL: nil) }
        if !isReleased {
            await withCheckedContinuation { parked.append($0) }
        }
        return (login: try gatedOutcome.get(), avatarURL: nil)
    }

    /// Resumes every parked call and lets later calls through ungated.
    func releaseAll() {
        isReleased = true
        for continuation in parked {
            continuation.resume()
        }
        parked.removeAll()
    }

    /// Polls until `count` calls are parked. Returns at the deadline without
    /// failing; the test's expectations then report the missing call.
    func waitForPendingValidations(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while parked.count < count {
            if ContinuousClock.now >= deadline { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func fetchPullRequests(query: String, cursor: String?) async throws -> PullRequestPage {
        PullRequestPage(pullRequests: [], nextCursor: nil)
    }

    func fetchTimeline(nodeID: String, cursor: String?, eventPageOffset: Int, checksPageOffset: Int) async throws -> TimelinePage {
        TimelinePage(events: [], checkRuns: [], reviewers: [], nextCursor: nil, checksNextCursor: nil)
    }

    func fetchChecks(nodeID: String, cursor: String, checksPageOffset: Int) async throws -> ChecksPage {
        ChecksPage(checkRuns: [], nextCursor: nil)
    }

    func fetchViewer() async throws -> (login: String, avatarURL: URL?) {
        (login: Self.ungatedLogin, avatarURL: nil)
    }

    func setDraft(pullRequestID: String, isDraft: Bool) async throws {}
}
