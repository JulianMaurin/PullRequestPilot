import Foundation
import os

/// Single source of truth for `(token, viewerLogin)`.
///
/// All mutations serialize through the actor. Swap operations are transactional:
/// either the full transition (validate → Keychain write → state commit) succeeds
/// and the new identity is visible, or any failure throws and the prior state is
/// preserved. There is no intermediate observable "half-swapped" state.
actor IdentityActor {
    private let keychain: KeychainService
    private let github: GitHubClientProtocol
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PullRequestPilot", category: "Identity")

    private(set) var state: IdentityState = .unauthenticated
    /// Bumped on every state mutation. Observers that launch async work capture
    /// this at start and re-check before committing a decision — stale results
    /// are discarded.
    private(set) var generation: UInt64 = 0

    /// Coalesces concurrent viewer-login fetches: if one is already in flight,
    /// additional callers await the same Task. Throwing so cancellation
    /// propagates to joiners instead of being swallowed as nil.
    private var pendingViewerLoginTask: Task<String?, Error>?

    init(keychain: KeychainService, github: GitHubClientProtocol) {
        self.keychain = keychain
        self.github = github
    }

    // MARK: - Read

    func token() -> String? {
        state.token
    }

    /// Returns the currently authenticated user's login. If authenticated but the
    /// login has not yet been fetched, fetches it from the API lazily. Throws
    /// `CancellationError` when the fetch is cancelled mid-flight so callers can
    /// distinguish "fetch didn't finish" from "fetch failed" — the latter was
    /// incorrectly triggering `.viewerIdentityUnavailable` on auto-refresh
    /// restart. Other errors still surface as `nil` (unlatched — next call retries).
    func currentViewerLogin() async throws -> String? {
        guard case .authenticated(let token, let cachedLogin) = state else { return nil }
        if let cachedLogin { return cachedLogin }

        if let pending = pendingViewerLoginTask {
            return try await pending.value
        }

        let capturedGeneration = generation
        let task = Task { [github, token] () throws -> String? in
            let viewer = try await github.validateToken(token)
            return viewer.login
        }
        pendingViewerLoginTask = task
        let result: String?
        do {
            result = try await task.value
        } catch is CancellationError {
            pendingViewerLoginTask = nil
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            pendingViewerLoginTask = nil
            throw CancellationError()
        } catch {
            pendingViewerLoginTask = nil
            logger.warning("currentViewerLogin fetch failed: \(error, privacy: .public)")
            return nil
        }
        pendingViewerLoginTask = nil

        guard let login = result,
              generation == capturedGeneration,
              case .authenticated(let currentToken, _) = state,
              currentToken == token
        else {
            return result
        }

        state = .authenticated(token: currentToken, viewerLogin: login)
        generation &+= 1
        return login
    }

    // MARK: - Write

    /// Loads any existing token from Keychain (or the DEBUG env var override) and
    /// transitions state accordingly. Called once at app launch. An unreadable
    /// keychain logs at `.error` and falls back to unauthenticated — the stored
    /// token is left in place for the next launch.
    func bootstrap() {
        if let token = initialStoredToken() {
            state = .authenticated(token: token, viewerLogin: nil)
        } else {
            state = .unauthenticated
        }
        generation &+= 1
    }

    /// Validates `newToken` against the GitHub API, writes it to the Keychain
    /// atomically, and commits state. On any failure, throws and leaves prior
    /// state untouched. `CancellationError` is rethrown as-is.
    @discardableResult
    func swap(to newToken: String) async throws -> String {
        let trimmed = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AuthError(reason: .invalidToken)
        }

        let viewer: (login: String, avatarURL: URL?)
        do {
            viewer = try await github.validateToken(trimmed)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch let clientError as GitHubClientError {
            switch clientError {
            case .unauthorized, .clientError, .graphQLErrors, .permissionDenied:
                throw AuthError(reason: .invalidToken, underlying: clientError)
            case .rateLimited, .serverError:
                throw AuthError(reason: .network, underlying: clientError)
            case .networkError, .decodingError:
                throw AuthError(reason: .network, underlying: clientError)
            }
        } catch {
            throw AuthError(reason: .unknown, underlying: error)
        }

        do {
            try keychain.save(key: Constants.Keychain.githubToken, value: trimmed)
        } catch {
            logger.error("Keychain save failed during swap: \(error, privacy: .public)")
            throw AuthError(reason: .saveFailed, underlying: error)
        }

        pendingViewerLoginTask?.cancel()
        pendingViewerLoginTask = nil
        state = .authenticated(token: trimmed, viewerLogin: viewer.login)
        generation &+= 1
        return viewer.login
    }

    /// Unconditionally clears in-memory state and the Keychain. Used on explicit
    /// sign-out and after a 401 confirms the token is revoked.
    func invalidate(reason: AuthInvalidReason) {
        logger.info("Invalidating identity: reason=\(String(describing: reason), privacy: .public)")
        pendingViewerLoginTask?.cancel()
        pendingViewerLoginTask = nil
        state = .unauthenticated
        generation &+= 1
        do {
            try keychain.delete(key: Constants.Keychain.githubToken)
        } catch {
            logger.error("Keychain delete during invalidate failed: \(error, privacy: .public)")
        }
    }

    /// Clears state and Keychain only if the currently authenticated token still
    /// matches `staleToken`. Prevents a late 401 for an already-replaced token
    /// from nuking a freshly saved valid one.
    @discardableResult
    func invalidateIfMatchingToken(_ staleToken: String, reason: AuthInvalidReason) -> Bool {
        guard case .authenticated(let current, _) = state, current == staleToken else {
            return false
        }
        invalidate(reason: reason)
        return true
    }

    // MARK: - Private

    private func initialStoredToken() -> String? {
        #if DEBUG
        if let envToken = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !envToken.isEmpty {
            return envToken
        }
        #endif
        do {
            return try keychain.readItem(key: Constants.Keychain.githubToken)
        } catch {
            logger.error("Keychain read failed during bootstrap; starting unauthenticated: \(error, privacy: .public)")
            return nil
        }
    }
}
