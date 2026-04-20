import Foundation
@testable import PullRequestPilot

enum IdentityActorTestFactory {
    /// Builds an IdentityActor backed by a unique test keychain suite so tests
    /// don't share Keychain state. Pass a mock client for validation.
    static func make(github: GitHubClientProtocol, suite: String = UUID().uuidString) -> IdentityActor {
        let keychain = KeychainService(service: "com.pullrequestpilot.identity.tests.\(suite)")
        try? keychain.delete(key: Constants.Keychain.githubToken)
        return IdentityActor(keychain: keychain, github: github)
    }

    /// Builds an IdentityActor and synchronously swaps in a test token using
    /// the mock's current `viewerLoginToReturn`. Use in tests that exercise
    /// any path depending on an authenticated identity (e.g. hideReviewed).
    static func makeAuthenticated(github: MockGitHubClient, suite: String = UUID().uuidString, token: String = "ghp_test") async throws -> IdentityActor {
        let identity = make(github: github, suite: suite)
        _ = try await identity.swap(to: token)
        return identity
    }
}
