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
