import Foundation
import Testing
@testable import PullRequestPilot

enum IdentityActorTestFactory {
    /// Test keychain services share this prefix; each suite gets its own
    /// service so parallel tests never share Keychain state.
    static let servicePrefix = "com.pullrequestpilot.identity.tests."

    /// IdentityActor plus its backing test keychain. `swap` persists the fake
    /// token into the real login keychain, and UUID-fresh service names are
    /// never revisited — so tests that swap manually must call
    /// `try deleteStoredToken()` after each successful swap. The actor serves the
    /// token from in-memory state after swap (only `bootstrap()` reads the
    /// keychain), so deleting immediately is behavior-neutral.
    struct Harness {
        let identity: IdentityActor
        private let keychain: KeychainService

        init(github: GitHubClientProtocol, suite: String) {
            let keychain = KeychainService(service: IdentityActorTestFactory.servicePrefix + suite)
            try? keychain.delete(key: Constants.Keychain.githubToken)
            self.keychain = keychain
            self.identity = IdentityActor(keychain: keychain, github: github)
        }

        func storedToken() throws -> String? {
            try keychain.readItem(key: Constants.Keychain.githubToken)
        }

        func deleteStoredToken() throws {
            try keychain.delete(key: Constants.Keychain.githubToken)
        }
    }

    /// Builds an IdentityActor backed by a unique test keychain suite so tests
    /// don't share Keychain state. Pass a mock client for validation. For
    /// tests that call `swap` themselves, use `makeHarness` instead so the
    /// persisted token can be cleaned up.
    static func make(github: GitHubClientProtocol, suite: String = UUID().uuidString) -> IdentityActor {
        makeHarness(github: github, suite: suite).identity
    }

    /// Variant of `make` for tests that swap tokens manually and need the
    /// backing keychain for cleanup.
    static func makeHarness(github: GitHubClientProtocol, suite: String = UUID().uuidString) -> Harness {
        Harness(github: github, suite: suite)
    }

    /// Builds an IdentityActor and synchronously swaps in a test token using
    /// the mock's current `viewerLoginToReturn`, then deletes the persisted
    /// token so no keychain item outlives the test. Use in tests that exercise
    /// any path depending on an authenticated identity (e.g. hideReviewed).
    static func makeAuthenticated(github: MockGitHubClient, suite: String = UUID().uuidString, token: String = "ghp_test") async throws -> IdentityActor {
        let harness = makeHarness(github: github, suite: suite)
        _ = try await harness.identity.swap(to: token)
        try harness.deleteStoredToken()
        return harness.identity
    }
}

// MARK: - Factory keychain hygiene

@Suite("IdentityActorTestFactory")
struct IdentityActorTestFactoryTests {
    @Test("makeAuthenticated deletes the persisted token after swap")
    func makeAuthenticatedLeavesNoKeychainItem() async throws {
        let suite = UUID().uuidString
        let identity = try await IdentityActorTestFactory.makeAuthenticated(github: MockGitHubClient(), suite: suite)

        let keychain = KeychainService(service: IdentityActorTestFactory.servicePrefix + suite)
        #expect(try keychain.readItem(key: Constants.Keychain.githubToken) == nil)
        // In-memory identity survives the keychain cleanup.
        #expect(await identity.token() == "ghp_test")
    }

    @Test("harness deleteStoredToken removes a manually swapped token")
    func harnessDeleteRemovesSwappedToken() async throws {
        let harness = IdentityActorTestFactory.makeHarness(github: MockGitHubClient())
        _ = try await harness.identity.swap(to: "ghp_manual")
        #expect(try harness.storedToken() == "ghp_manual")

        try harness.deleteStoredToken()

        #expect(try harness.storedToken() == nil)
        #expect(await harness.identity.token() == "ghp_manual")
    }

    @Test("make persists nothing without a swap")
    func makeWritesNoKeychainItem() throws {
        let suite = UUID().uuidString
        _ = IdentityActorTestFactory.make(github: MockGitHubClient(), suite: suite)

        let keychain = KeychainService(service: IdentityActorTestFactory.servicePrefix + suite)
        #expect(try keychain.readItem(key: Constants.Keychain.githubToken) == nil)
    }
}
