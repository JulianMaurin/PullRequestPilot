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
    private let logger = Logger(category: "Identity")

    private(set) var state: IdentityState = .unauthenticated
    /// Bumped on every state mutation. Observers that launch async work capture
    /// this at start and re-check before committing a decision — stale results
    /// are discarded.
    private(set) var generation: UInt64 = 0

    /// Coalesces concurrent viewer-login fetches: if one is already in flight,
    /// additional callers await the same Task. Throwing so cancellation
    /// propagates to joiners instead of being swallowed as nil.
    private var pendingViewerLoginTask: Task<String?, Error>?

    /// Coalesces concurrent 401 revalidations — a failing refresh cycle fires
    /// one 401 per view, and only one confirmation round-trip should run.
    private var pendingRevalidationTask: Task<Void, Never>?

    /// Every invalidation's reason, including ones no UI initiated (a confirmed
    /// 401). Single consumer: SettingsViewModel.
    nonisolated let invalidations: AsyncStream<AuthInvalidReason>
    private let invalidationContinuation: AsyncStream<AuthInvalidReason>.Continuation

    /// `storedToken` is the launch-time value from `readStoredToken(from:)`;
    /// nil starts unauthenticated.
    init(keychain: KeychainService, github: GitHubClientProtocol, storedToken: String? = nil) {
        self.keychain = keychain
        self.github = github
        if let storedToken {
            state = .authenticated(token: storedToken, viewerLogin: nil)
        }
        (invalidations, invalidationContinuation) = AsyncStream.makeStream(
            of: AuthInvalidReason.self,
            bufferingPolicy: .bufferingNewest(1)
        )
    }

    deinit {
        invalidationContinuation.finish()
    }

    /// The launch-time token: the DEBUG `GITHUB_TOKEN` override, else the
    /// Keychain. Throws when the Keychain is unreadable (locked, denied ACL),
    /// which callers must not treat as "no token saved".
    static func readStoredToken(from keychain: KeychainService) throws -> String? {
        #if DEBUG
        if let envToken = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !envToken.isEmpty {
            return envToken
        }
        #endif
        return try keychain.readItem(key: Constants.Keychain.githubToken)
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

    /// Validates `newToken` against the GitHub API, writes it to the Keychain
    /// atomically, and commits state. On any failure, throws and leaves prior
    /// state untouched. `CancellationError` is rethrown as-is.
    @discardableResult
    func swap(to newToken: String) async throws -> TokenValidation {
        let trimmed = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AuthError(reason: .invalidToken)
        }

        let viewer: TokenValidation
        do {
            viewer = try await github.validateToken(trimmed)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch let clientError as GitHubClientError {
            switch clientError {
            case .missingToken, .unauthorized, .clientError, .graphQLErrors, .permissionDenied:
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
        return viewer
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
        invalidationContinuation.yield(reason)
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

    /// Entry point for the client's 401 callback. A single 401 must not
    /// destroy the stored token: GitHub and intermediary proxies return
    /// transient auth failures, and deleting the Keychain on one bad response
    /// left users signed out across relaunches with a token that still
    /// worked when re-pasted. The token is re-validated once; only a
    /// confirmed 401 invalidates. Inconclusive outcomes (network, server,
    /// rate limit) keep the token — the next 401 re-runs the check.
    func handleUnauthorized(staleToken: String) async {
        guard case .authenticated(let current, _) = state, current == staleToken else { return }
        if let pending = pendingRevalidationTask {
            await pending.value
            return
        }
        // The revalidation's own 401 fires the client's onUnauthorized again;
        // that re-entrant call joins this task above and cannot recurse.
        let task = Task { await self.revalidate(staleToken: staleToken) }
        pendingRevalidationTask = task
        await task.value
        pendingRevalidationTask = nil
    }

    private func revalidate(staleToken: String) async {
        do {
            _ = try await github.validateToken(staleToken)
            logger.warning("401 received but token re-validated; keeping identity (transient auth failure)")
        } catch let clientError as GitHubClientError {
            guard case .unauthorized = clientError else {
                logger.warning("401 revalidation inconclusive; keeping token: \(clientError, privacy: .public)")
                return
            }
            invalidateIfMatchingToken(staleToken, reason: .unauthorized)
        } catch {
            logger.warning("401 revalidation inconclusive; keeping token: \(error, privacy: .public)")
        }
    }
}
