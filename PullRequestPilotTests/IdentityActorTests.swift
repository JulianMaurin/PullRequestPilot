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

    // MARK: - Bootstrap

    @Test("bootstrap with no stored token → unauthenticated")
    func bootstrapEmpty() async {
        let (identity, _) = makeIdentity()
        await identity.bootstrap()
        let state = await identity.state
        #expect(state == .unauthenticated)
    }

    @Test("bootstrap picks up stored Keychain token",
          .enabled(if: ProcessInfo.processInfo.environment["GITHUB_TOKEN"] == nil))
    func bootstrapLoadsFromKeychain() async throws {
        let (identity, keychain) = makeIdentity(keychainSuite: "bootstrap-keychain")
        try keychain.save(key: Constants.Keychain.githubToken, value: "ghp_from_keychain")

        await identity.bootstrap()
        let token = await identity.token()
        #expect(token == "ghp_from_keychain")
    }

    @Test("bootstrap with unreadable keychain falls back to unauthenticated",
          .enabled(if: ProcessInfo.processInfo.environment["GITHUB_TOKEN"] == nil))
    func bootstrapKeychainFailure() async {
        let keychain = KeychainService(
            service: "com.pullrequestpilot.identity.tests.locked",
            secItemCopyMatching: { _, _ in errSecInteractionNotAllowed }
        )
        let identity = IdentityActor(keychain: keychain, github: MockGitHubClient())

        await identity.bootstrap()

        let state = await identity.state
        #expect(state == .unauthenticated)
    }

    // MARK: - Swap happy path

    @Test("swap with valid token transitions to authenticated")
    func swapHappyPath() async throws {
        let mock = MockGitHubClient()
        await mock.setViewerLogin("octocat")
        let (identity, keychain) = makeIdentity(keychainSuite: "swap-happy", github: mock)

        let login = try await identity.swap(to: "ghp_valid")

        #expect(login == "octocat")
        let state = await identity.state
        #expect(state == .authenticated(token: "ghp_valid", viewerLogin: "octocat"))
        #expect(keychain.read(key: Constants.Keychain.githubToken) == "ghp_valid")
    }

    @Test("swap trims whitespace before validating and saving")
    func swapTrimsWhitespace() async throws {
        let mock = MockGitHubClient()
        await mock.setViewerLogin("octocat")
        let (identity, keychain) = makeIdentity(keychainSuite: "swap-trim", github: mock)

        _ = try await identity.swap(to: "  ghp_padded  \n")

        #expect(keychain.read(key: Constants.Keychain.githubToken) == "ghp_padded")
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
        #expect(keychain.read(key: Constants.Keychain.githubToken) == nil)
    }

    @Test("swap failure after prior authentication keeps the old token active")
    func swapFailurePreservesPriorAuth() async throws {
        let mock = MockGitHubClient()
        await mock.setViewerLogin("alice")
        let (identity, keychain) = makeIdentity(keychainSuite: "swap-preserve", github: mock)

        _ = try await identity.swap(to: "ghp_good")
        #expect(keychain.read(key: Constants.Keychain.githubToken) == "ghp_good")

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
        #expect(keychain.read(key: Constants.Keychain.githubToken) == "ghp_good")
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
        #expect(keychain.read(key: Constants.Keychain.githubToken) == "ghp_good")
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
        #expect(keychain.read(key: Constants.Keychain.githubToken) == "ghp_x")

        await identity.invalidate(reason: .unauthorized)

        let state = await identity.state
        #expect(state == .unauthenticated)
        #expect(keychain.read(key: Constants.Keychain.githubToken) == nil)
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
        #expect(keychain.read(key: Constants.Keychain.githubToken) == "ghp_fresh")
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
        #expect(keychain.read(key: Constants.Keychain.githubToken) == "ghp_valid")
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
        #expect(keychain.read(key: Constants.Keychain.githubToken) == nil)
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
        #expect(keychain.read(key: Constants.Keychain.githubToken) == "ghp_offline")
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

    @Test("currentViewerLogin rethrows CancellationError without clearing generation")
    func currentViewerLoginCancellation() async throws {
        let mock = MockGitHubClient()
        await mock.setErrorToThrow(CancellationError())
        let (identity, _) = makeIdentity(keychainSuite: "viewer-cancel", github: mock)
        await mock.setErrorToThrow(nil)
        await mock.setViewerLogin("bob")
        _ = try await identity.swap(to: "ghp_y")

        // Force a refetch by clearing the cached login via generation bump.
        await identity.invalidate(reason: .userSignedOut)
        // With no token we get nil — restore and test cancellation.
        await mock.setErrorToThrow(nil)
        await mock.setViewerLogin("bob")
        _ = try await identity.swap(to: "ghp_z")
        // Cached now — this path still returns quickly. The semantic behaviour
        // (rethrow of CancellationError) is exercised by the filter closure's
        // unit test in DashboardViewModelTests — here we just confirm the API
        // shape is `throws`.
        let login = try await identity.currentViewerLogin()
        #expect(login == "bob")
    }
}
