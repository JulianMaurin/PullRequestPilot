import Foundation

/// In-memory cache for the GitHub token to avoid repeated Keychain access prompts.
/// Reads from Keychain once on first access; call `invalidate()` after saving a new token.
final class TokenCache: @unchecked Sendable {
    private let keychain: KeychainService
    private var cachedToken: String?
    private var hasLoaded = false
    private let lock = NSLock()

    init(keychain: KeychainService) {
        self.keychain = keychain
    }

    var token: String? {
        lock.lock()
        defer { lock.unlock() }
        if !hasLoaded {
            // In debug builds, check environment variable first (set via .env or Xcode scheme)
            #if DEBUG
            if let envToken = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !envToken.isEmpty {
                cachedToken = envToken
                hasLoaded = true
                return cachedToken
            }
            #endif
            cachedToken = keychain.read(key: Constants.Keychain.githubToken)
            hasLoaded = true
        }
        return cachedToken
    }

    func set(_ newToken: String) {
        lock.lock()
        defer { lock.unlock() }
        cachedToken = newToken
        hasLoaded = true
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        cachedToken = nil
        hasLoaded = false
    }
}
