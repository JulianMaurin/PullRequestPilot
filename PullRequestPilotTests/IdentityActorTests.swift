import Testing
import Foundation
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

    // MARK: - Swap happy path

    @Test("swap with valid token transitions to authenticated")
    func swapHappyPath() async throws {
        let mock = MockGitHubClient()
        mock.viewerLoginToReturn = "octocat"
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
        mock.viewerLoginToReturn = "octocat"
        let (identity, keychain) = makeIdentity(keychainSuite: "swap-trim", github: mock)

        _ = try await identity.swap(to: "  ghp_padded  \n")

        #expect(keychain.read(key: Constants.Keychain.githubToken) == "ghp_padded")
        #expect(mock.receivedValidateTokens.last == "ghp_padded")
    }

    // MARK: - Swap failure: prior state preserved

    @Test("swap with invalid token throws .invalidToken and does NOT write Keychain")
    func swapInvalidTokenPreservesKeychain() async throws {
        let mock = MockGitHubClient()
        mock.validateTokenError = GitHubClientError.unauthorized
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
        mock.viewerLoginToReturn = "alice"
        let (identity, keychain) = makeIdentity(keychainSuite: "swap-preserve", github: mock)

        _ = try await identity.swap(to: "ghp_good")
        #expect(keychain.read(key: Constants.Keychain.githubToken) == "ghp_good")

        // Now attempt a bad token
        mock.validateTokenError = GitHubClientError.unauthorized
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
        mock.viewerLoginToReturn = "alice"
        let (identity, keychain) = makeIdentity(keychainSuite: "swap-cancel", github: mock)

        _ = try await identity.swap(to: "ghp_good")

        mock.validateTokenError = CancellationError()
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
        mock.validateTokenError = URLError(.cancelled)
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
        mock.viewerLoginToReturn = "alice"
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
        mock.viewerLoginToReturn = "alice"
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
        mock.viewerLoginToReturn = "alice"
        let (identity, _) = makeIdentity(keychainSuite: "invalidate-match", github: mock)

        _ = try await identity.swap(to: "ghp_same")

        let invalidated = await identity.invalidateIfMatchingToken("ghp_same", reason: .unauthorized)
        #expect(invalidated)
        let state = await identity.state
        #expect(state == .unauthenticated)
    }

    // MARK: - Concurrent swaps

    @Test("concurrent swaps serialize; last committed wins")
    func concurrentSwapsSerialize() async throws {
        let mock = MockGitHubClient()
        mock.viewerLoginToReturn = "user"
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
        #expect(mock.validateTokenCallCount == 3)
    }

    // MARK: - currentViewerLogin

    @Test("currentViewerLogin returns nil when unauthenticated")
    func currentViewerLoginUnauth() async {
        let (identity, _) = makeIdentity()
        let login = await identity.currentViewerLogin()
        #expect(login == nil)
    }

    @Test("currentViewerLogin returns cached login without refetch")
    func currentViewerLoginCached() async throws {
        let mock = MockGitHubClient()
        mock.viewerLoginToReturn = "alice"
        let (identity, _) = makeIdentity(keychainSuite: "viewer-cached", github: mock)

        _ = try await identity.swap(to: "ghp_x")
        let callsAfterSwap = mock.validateTokenCallCount

        let login = await identity.currentViewerLogin()
        #expect(login == "alice")
        #expect(mock.validateTokenCallCount == callsAfterSwap)
    }
}
