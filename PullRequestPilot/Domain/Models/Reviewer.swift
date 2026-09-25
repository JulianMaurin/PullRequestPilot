import Foundation

// MARK: - Model

struct Reviewer: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let avatarURL: URL?
    let isTeam: Bool
    let state: ReviewerState
}

// MARK: - State

enum ReviewerState: Hashable, Sendable {
    case pending
    case approved
    case changesRequested
    case commented
    case dismissed

    /// Priority for deduplication: higher = kept when a user has multiple reviews.
    var priority: Int {
        switch self {
        case .approved: return 4
        case .changesRequested: return 3
        case .commented: return 2
        case .dismissed: return 1
        case .pending: return 0
        }
    }

    var iconName: String {
        switch self {
        case .pending: return "clock"
        case .approved: return "checkmark"
        case .changesRequested: return "xmark"
        case .commented: return "text.bubble"
        case .dismissed: return "arrow.uturn.left"
        }
    }

    var iconTint: StatusTint {
        switch self {
        case .approved: return .green
        case .changesRequested: return .red
        case .commented: return .blue
        case .pending: return .yellow
        case .dismissed: return .gray
        }
    }

    var label: String {
        switch self {
        case .pending: return "Awaiting review"
        case .approved: return "Approved"
        case .changesRequested: return "Changes requested"
        case .commented: return "Commented"
        case .dismissed: return "Dismissed"
        }
    }
}
