import Foundation

// The widget stores these next to the app's list data, so a new case has to
// be drawn (exhaustive switches) on both sides.

enum PullRequestState: String, Codable, Sendable {
    case open = "OPEN"
    case closed = "CLOSED"
    case merged = "MERGED"
}

/// The rollup of every check and commit status on the head commit.
enum CheckStatus: String, Codable, Sendable {
    case pending = "PENDING"
    case success = "SUCCESS"
    case failure = "FAILURE"
    case error = "ERROR"
    case expected = "EXPECTED"
}

enum ReviewDecision: String, Codable, Sendable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case reviewRequired = "REVIEW_REQUIRED"
}
