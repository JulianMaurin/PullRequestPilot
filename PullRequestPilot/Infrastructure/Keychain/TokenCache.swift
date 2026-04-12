import Foundation

/// In-memory cache for the GitHub token to avoid repeated Keychain access prompts.
/// Reads from Keychain once on first access; call `invalidate()` after saving a new token.
final class TokenCache: @unchecked Sendable {
    private let keychain: KeychainService
    private var cachedToken: String?
    private var hasLoaded = false
    private let lock = NSLock()
    /// Monotonically increasing generation counter. Each `invalidate()` bumps this,
    /// allowing a concurrent Keychain read to detect that its result is stale.
    private var generation: UInt64 = 0

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
        let capturedGeneration = generation
        lock.unlock()

        #if DEBUG
        if let envToken = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !envToken.isEmpty {
            lock.lock()
            defer { lock.unlock() }
            if generation == capturedGeneration, !hasLoaded {
                cachedToken = envToken
                hasLoaded = true
            }
            return cachedToken
        }
        #endif

        // Perform Keychain I/O outside the lock to avoid blocking other threads
        // if macOS shows a Keychain access dialog.
        let value = keychain.read(key: Constants.Keychain.githubToken)

        lock.lock()
        defer { lock.unlock() }
        // Only store the result if no invalidation occurred while we were reading.
        // If generation changed, another thread called invalidate() or set(), so
        // our Keychain read is stale — discard it.
        if generation == capturedGeneration, !hasLoaded {
            cachedToken = value
            hasLoaded = true
        }
        return cachedToken
    }

    func set(_ newToken: String) {
        lock.lock()
        defer { lock.unlock() }
        cachedToken = newToken
        hasLoaded = true
        generation &+= 1
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        cachedToken = nil
        hasLoaded = false
        generation &+= 1
    }

    /// Invalidates only if the given token matches the currently cached value.
    /// Prevents stale 401 responses from clearing a freshly-saved valid token.
    func invalidateIfCurrent(_ token: String) {
        lock.lock()
        defer { lock.unlock() }
        guard cachedToken == token else { return }
        cachedToken = nil
        hasLoaded = false
        generation &+= 1
    }
}
