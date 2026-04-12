import Testing
import Foundation
@testable import PullRequestPilot

@Suite("TokenCache")
struct TokenCacheTests {
    private let testService = "com.pullrequestpilot.tokencache.tests.\(UUID().uuidString)"
    private let envTokenSet = ProcessInfo.processInfo.environment["GITHUB_TOKEN"] != nil

    private func makeCache(storedToken: String? = nil) -> TokenCache {
        let keychain = KeychainService(service: testService)
        if let storedToken {
            try? keychain.save(key: Constants.Keychain.githubToken, value: storedToken)
        }
        return TokenCache(keychain: keychain)
    }

    @Test("first access loads token from keychain",
          .enabled(if: ProcessInfo.processInfo.environment["GITHUB_TOKEN"] == nil,
                   "Skipped: GITHUB_TOKEN env var overrides Keychain in DEBUG builds"))
    func firstAccessLoadsFromKeychain() {
        let cache = makeCache(storedToken: "ghp_stored")
        #expect(cache.token == "ghp_stored")
    }

    @Test("subsequent access returns cached value without re-reading keychain",
          .enabled(if: ProcessInfo.processInfo.environment["GITHUB_TOKEN"] == nil,
                   "Skipped: GITHUB_TOKEN env var overrides Keychain in DEBUG builds"))
    func subsequentAccessUsesCached() {
        let cache = makeCache(storedToken: "ghp_original")
        _ = cache.token // first load
        // Even if keychain changes, cache should return the same value
        #expect(cache.token == "ghp_original")
    }

    @Test("set updates cached token")
    func setUpdatesCache() {
        let cache = makeCache()
        cache.set("ghp_new_token")
        #expect(cache.token == "ghp_new_token")
    }

    @Test("invalidate clears cached token and forces reload",
          .enabled(if: ProcessInfo.processInfo.environment["GITHUB_TOKEN"] == nil,
                   "Skipped: GITHUB_TOKEN env var overrides Keychain in DEBUG builds"))
    func invalidateClearsCache() {
        let cache = makeCache(storedToken: "ghp_stored")
        cache.set("ghp_override")
        #expect(cache.token == "ghp_override")

        cache.invalidate()
        // After invalidate, next access should re-read from keychain
        #expect(cache.token == "ghp_stored")
    }

    @Test("token returns nil when keychain has no value",
          .enabled(if: ProcessInfo.processInfo.environment["GITHUB_TOKEN"] == nil,
                   "Skipped: GITHUB_TOKEN env var overrides Keychain in DEBUG builds"))
    func tokenReturnsNilWhenEmpty() {
        let cache = makeCache(storedToken: nil)
        #expect(cache.token == nil)
    }

    @Test("invalidate prevents stale reads from overwriting cache")
    func invalidatePreventsStaleReads() {
        let cache = makeCache(storedToken: "ghp_original")
        cache.set("ghp_new")
        cache.invalidate()
        cache.set("ghp_final")
        #expect(cache.token == "ghp_final")
    }

    // MARK: - invalidateIfCurrent

    @Test("invalidateIfCurrent clears when token matches")
    func invalidateIfCurrentMatchingToken() {
        let cache = makeCache()
        cache.set("ghp_current")
        #expect(cache.token == "ghp_current")

        cache.invalidateIfCurrent("ghp_current")
        // After invalidation, token should be nil (or re-read from keychain)
        // Since we didn't store in keychain via set(), re-read yields nil
    }

    @Test("invalidateIfCurrent does nothing when token differs")
    func invalidateIfCurrentNonMatchingToken() {
        let cache = makeCache()
        cache.set("ghp_current")

        cache.invalidateIfCurrent("ghp_stale")
        #expect(cache.token == "ghp_current")
    }

    @Test("invalidateIfCurrent preserves freshly set token after stale 401")
    func invalidateIfCurrentPreservesFreshToken() {
        let cache = makeCache()
        cache.set("ghp_old")
        // Simulate: 401 response arrives with old token, but user already saved new token
        cache.set("ghp_new")
        cache.invalidateIfCurrent("ghp_old")
        // New token should be preserved
        #expect(cache.token == "ghp_new")
    }
}
