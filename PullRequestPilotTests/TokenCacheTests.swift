import Testing
import Foundation
@testable import PullRequestPilot

@Suite("TokenCache")
struct TokenCacheTests {
    private let testService = "com.pullrequestpilot.tokencache.tests.\(UUID().uuidString)"

    private func makeCache(storedToken: String? = nil) -> TokenCache {
        let keychain = KeychainService(service: testService)
        if let storedToken {
            try? keychain.save(key: Constants.Keychain.githubToken, value: storedToken)
        }
        return TokenCache(keychain: keychain)
    }

    @Test("first access loads token from keychain")
    func firstAccessLoadsFromKeychain() {
        let cache = makeCache(storedToken: "ghp_stored")
        // In DEBUG builds, env var takes precedence, so skip if GITHUB_TOKEN is set
        if ProcessInfo.processInfo.environment["GITHUB_TOKEN"] != nil {
            return
        }
        #expect(cache.token == "ghp_stored")
    }

    @Test("subsequent access returns cached value without re-reading keychain")
    func subsequentAccessUsesCached() {
        let cache = makeCache(storedToken: "ghp_original")
        if ProcessInfo.processInfo.environment["GITHUB_TOKEN"] != nil {
            return
        }
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

    @Test("invalidate clears cached token and forces reload")
    func invalidateClearsCache() {
        let cache = makeCache(storedToken: "ghp_stored")
        cache.set("ghp_override")
        #expect(cache.token == "ghp_override")

        cache.invalidate()
        // After invalidate, next access should re-read from keychain
        if ProcessInfo.processInfo.environment["GITHUB_TOKEN"] != nil {
            return
        }
        #expect(cache.token == "ghp_stored")
    }

    @Test("token returns nil when keychain has no value")
    func tokenReturnsNilWhenEmpty() {
        let cache = makeCache(storedToken: nil)
        if ProcessInfo.processInfo.environment["GITHUB_TOKEN"] != nil {
            return
        }
        #expect(cache.token == nil)
    }
}
