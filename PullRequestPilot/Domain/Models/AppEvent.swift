import Foundation

// MARK: - AppEvent

/// A user-visible event posted through `EventCenter`. Rendered as toasts,
/// inline banners, or diagnostic log entries.
struct AppEvent: Sendable, Identifiable, Equatable {
    enum Level: Sendable {
        case error
        case warning
        case info
    }

    enum Payload: Sendable, Equatable {
        case error(AppError)
        case warning(String)
        case info(String)
    }

    let id: UUID
    let payload: Payload
    let postedAt: Date
    let autoDismissAfter: Duration?

    init(id: UUID = UUID(), payload: Payload, postedAt: Date = .now, autoDismissAfter: Duration? = nil) {
        self.id = id
        self.payload = payload
        self.postedAt = postedAt
        self.autoDismissAfter = autoDismissAfter
    }

    var level: Level {
        switch payload {
        case .error: return .error
        case .warning: return .warning
        case .info: return .info
        }
    }

    var appError: AppError? {
        if case .error(let error) = payload { return error }
        return nil
    }

    var message: String {
        switch payload {
        case .error(let error): return error.errorDescription ?? "Something went wrong."
        case .warning(let text), .info(let text): return text
        }
    }

    // MARK: - Convenience constructors

    static func error(_ error: AppError, autoDismissAfter: Duration? = nil) -> AppEvent {
        AppEvent(payload: .error(error), autoDismissAfter: autoDismissAfter)
    }

    static func warning(_ text: String, autoDismissAfter: Duration? = .seconds(6)) -> AppEvent {
        AppEvent(payload: .warning(text), autoDismissAfter: autoDismissAfter)
    }

    static func info(_ text: String, autoDismissAfter: Duration? = .seconds(4)) -> AppEvent {
        AppEvent(payload: .info(text), autoDismissAfter: autoDismissAfter)
    }
}

// MARK: - AppError

/// Canonical user-visible error type. Every subsystem failure that should
/// surface to the user maps to one of these cases.
enum AppError: LocalizedError, Sendable, Hashable {
    case unauthorized
    case rateLimited(resetAt: Date?)
    case permissionDenied(detail: String?)
    case network(underlying: String)
    case serverError(statusCode: Int)
    case graphQLErrors([String])
    case decodeResponse(detail: String)
    case tokenSaveFailed(underlying: String)
    case decodeCorruption(subsystem: String, backupPath: String?)
    case bookmarkPruned(count: Int)
    case bookmarkCreationFailed(path: String)
    case viewerIdentityUnavailable
    case launchAtLoginFailed(underlying: String)
    case widgetSaveFailed(underlying: String)
    case externalAppLaunchFailed(appName: String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Your GitHub token is invalid or expired. Update it in Settings."
        case .rateLimited(let resetAt):
            if let resetAt {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .full
                let phrase = formatter.localizedString(for: resetAt, relativeTo: .now)
                return "GitHub rate limit exceeded. Try again \(phrase)."
            }
            return "GitHub rate limit exceeded. Try again in a few minutes."
        case .permissionDenied(let detail):
            if let detail, !detail.isEmpty {
                return "GitHub refused the request: \(detail)."
            }
            return "GitHub refused the request. Check that your token has the required scopes."
        case .network(let underlying):
            return "Network error: \(underlying)"
        case .serverError(let statusCode):
            return "GitHub is experiencing issues (HTTP \(statusCode)). Try again later."
        case .graphQLErrors(let messages):
            return "GitHub API error: \(messages.joined(separator: "; "))"
        case .decodeResponse(let detail):
            return "Unexpected response from GitHub: \(detail)."
        case .tokenSaveFailed(let underlying):
            return "Could not save your GitHub token to the Keychain: \(underlying)"
        case .decodeCorruption(let subsystem, let backupPath):
            let base = "Couldn't read stored \(subsystem). A backup was saved to disk so no data was lost."
            if let backupPath {
                return base + " Backup: \(backupPath)"
            }
            return base
        case .bookmarkPruned(let count):
            let noun = count == 1 ? "directory" : "directories"
            let pronoun = count == 1 ? "it" : "them"
            return "\(count) \(noun) lost sandbox access and \(count == 1 ? "was" : "were") removed. Re-add \(pronoun) in Settings."
        case .bookmarkCreationFailed(let path):
            return "Couldn't store a sandbox bookmark for \(path). The directory wasn't added."
        case .viewerIdentityUnavailable:
            return "Your GitHub identity isn't available yet. The hide-reviewed filter has been disabled."
        case .launchAtLoginFailed(let underlying):
            return "Could not update launch-at-login: \(underlying)"
        case .widgetSaveFailed(let underlying):
            return "Couldn't update widget data: \(underlying)"
        case .externalAppLaunchFailed(let appName):
            return "Couldn't open \(appName). Make sure it's installed and try again."
        }
    }

    /// True when the underlying cause is offline / connectivity. Used to pick
    /// a dedicated empty-state UI ("No connection") instead of a generic error.
    var isNetworkFailure: Bool {
        switch self {
        case .network: return true
        default: return false
        }
    }
}
