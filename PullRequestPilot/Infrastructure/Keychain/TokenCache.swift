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
        if hasLoaded {
            let cached = cachedToken
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Perform Keychain I/O outside the lock to avoid blocking other threads
        // if macOS shows a Keychain access dialog.
        #if DEBUG
        if let envToken = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !envToken.isEmpty {
            lock.lock()
            cachedToken = envToken
            hasLoaded = true
            lock.unlock()
            return envToken
        }
        #endif
        let value = keychain.read(key: Constants.Keychain.githubToken)

        lock.lock()
        // Double-check: another thread may have loaded while we were reading
        if !hasLoaded {
            cachedToken = value
            hasLoaded = true
        }
        let result = cachedToken
        lock.unlock()
        return result
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
