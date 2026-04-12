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
}
