import Foundation

struct CheckRun: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let status: CheckRunStatus
    let conclusion: CheckRunConclusion?
    let detailsURL: URL?
    let isRequired: Bool

    /// Priority for deduplication: higher = preferred when multiple runs share a name.
    var conclusionPriority: Int {
        switch conclusion {
        case nil: return 5 // in-progress / pending — active runs always win over completed
        case .success: return 4
        case .failure, .startupFailure, .timedOut: return 2
        case .neutral, .actionRequired: return 1
        case .cancelled, .skipped, .stale: return 0
        }
    }

    var displayStatus: String {
        if let conclusion {
            return conclusion.label
        }
        return status.label
    }

    var iconName: String {
        if let conclusion {
            return conclusion.iconName
        }
        return status.iconName
    }

    var iconColor: String {
        if let conclusion {
            return conclusion.iconColor
        }
        return status.iconColor
    }
}

enum CheckRunStatus: String, Sendable {
    case queued = "QUEUED"
    case inProgress = "IN_PROGRESS"
    case completed = "COMPLETED"
    case waiting = "WAITING"
    case pending = "PENDING"
    case requested = "REQUESTED"

    var label: String {
        switch self {
        case .queued: return "Queued"
        case .inProgress: return "In progress"
        case .completed: return "Completed"
        case .waiting: return "Waiting"
        case .pending: return "Pending"
        case .requested: return "Requested"
        }
    }

    var iconName: String {
        switch self {
        case .queued, .waiting, .pending, .requested: return "clock"
        case .inProgress: return "circle.fill"
        case .completed: return "checkmark"
        }
    }

    var iconColor: String {
        switch self {
        case .queued, .waiting, .pending, .requested: return "gray"
        case .inProgress: return "yellow"
        case .completed: return "green"
        }
    }
}

enum CheckRunConclusion: String, Sendable {
    case success = "SUCCESS"
    case failure = "FAILURE"
    case neutral = "NEUTRAL"
    case cancelled = "CANCELLED"
    case timedOut = "TIMED_OUT"
    case actionRequired = "ACTION_REQUIRED"
    case skipped = "SKIPPED"
    case stale = "STALE"
    case startupFailure = "STARTUP_FAILURE"

    var label: String {
        switch self {
        case .success: return "Success"
        case .failure: return "Failure"
        case .neutral: return "Neutral"
        case .cancelled: return "Cancelled"
        case .timedOut: return "Timed out"
        case .actionRequired: return "Action required"
        case .skipped: return "Skipped"
        case .stale: return "Stale"
        case .startupFailure: return "Startup failure"
        }
    }

    var iconName: String {
        switch self {
        case .success: return "checkmark"
        case .failure, .startupFailure: return "xmark"
        case .cancelled, .timedOut: return "xmark.circle"
        case .neutral, .stale: return "minus"
        case .actionRequired: return "exclamationmark.triangle"
        case .skipped: return "arrow.right"
        }
    }

    var iconColor: String {
        switch self {
        case .success: return "green"
        case .failure, .startupFailure, .timedOut: return "red"
        case .cancelled, .stale: return "gray"
        case .neutral, .skipped: return "gray"
        case .actionRequired: return "yellow"
        }
    }
}
