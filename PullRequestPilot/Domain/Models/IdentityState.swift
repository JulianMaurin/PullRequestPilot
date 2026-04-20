import Foundation

enum IdentityState: Sendable, Equatable {
    case unauthenticated
    case authenticated(token: String, viewerLogin: String?)

    var isAuthenticated: Bool {
        if case .authenticated = self { return true }
        return false
    }

    var token: String? {
        if case .authenticated(let token, _) = self { return token }
        return nil
    }

    var viewerLogin: String? {
        if case .authenticated(_, let login) = self { return login }
        return nil
    }
}

enum AuthInvalidReason: Sendable, Equatable {
    case invalidToken
    case saveFailed
    case network
    case unauthorized
    case userSignedOut
    case unknown
}

struct AuthError: LocalizedError {
    let reason: AuthInvalidReason
    let underlying: Error?

    init(reason: AuthInvalidReason, underlying: Error? = nil) {
        self.reason = reason
        self.underlying = underlying
    }

    var errorDescription: String? {
        switch reason {
        case .invalidToken:
            "Token is invalid or expired. Generate a new one at github.com/settings/tokens."
        case .saveFailed:
            "Could not save token to Keychain. Check that the app has Keychain access."
        case .network:
            "Could not reach GitHub to validate the token. Check your internet connection."
        case .unauthorized:
            "GitHub rejected the stored token. Sign in again."
        case .userSignedOut:
            "Signed out."
        case .unknown:
            "Something went wrong. Check the logs for details."
        }
    }
}
