import Foundation

struct CheckRun: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let status: CheckRunStatus
    let conclusion: CheckRunConclusion?
    let detailsURL: URL?
    let isRequired: Bool
    /// GitHub Actions workflow-run database ID. `nil` for `StatusContext`
    /// entries (commit statuses from non-Actions CI systems) and for rare
    /// CheckRuns without a check suite. Distinguishes two workflows that
    /// happen to produce checks with the same name.
    let workflowRunID: Int?
    /// When GitHub started this check run. Used to pick the latest attempt
    /// within a `(name, workflowRunID)` group. `nil` falls back to
    /// `conclusionPriority`.
    let startedAt: Date?
    /// A commit status (`StatusContext`, from a CI outside GitHub Actions)
    /// rather than a check run.
    let isCommitStatus: Bool

    init(
        id: String,
        name: String,
        status: CheckRunStatus,
        conclusion: CheckRunConclusion?,
        detailsURL: URL?,
        isRequired: Bool,
        workflowRunID: Int?,
        startedAt: Date?,
        isCommitStatus: Bool = false
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.detailsURL = detailsURL
        self.isRequired = isRequired
        self.workflowRunID = workflowRunID
        self.startedAt = startedAt
        self.isCommitStatus = isCommitStatus
    }

    /// Priority for deduplication fallback: higher = preferred when two runs
    /// in the same group have equal / missing `startedAt`.
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

    var iconTint: StatusTint {
        if let conclusion {
            return conclusion.iconTint
        }
        return status.iconTint
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

    var iconTint: StatusTint {
        switch self {
        case .queued, .waiting, .pending, .requested: return .gray
        case .inProgress: return .yellow
        case .completed: return .green
        }
    }
}

/// Grouping key for CheckRun dedupe. Hoisted out of the extension because
/// Swift does not allow types to be nested in generic methods.
struct CheckRunDedupeKey: Hashable {
    let name: String
    let workflowRunID: Int?
}

extension Array where Element == CheckRun {
    /// Dedupes check runs by `(name, workflowRunID)`, across every page of a
    /// pull request's checks at once. Within a group, the run with the latest
    /// `startedAt` wins — if timestamps tie or are missing, falls back to
    /// `conclusionPriority`. This collapses workflow re-runs to their latest
    /// attempt while keeping distinct workflows that share a job name as
    /// separate entries.
    ///
    /// Entries with `workflowRunID == nil` (commit statuses, orphan check
    /// runs) dedupe by name alone. A check run and a commit status in one
    /// group are the same check reported twice: the check run wins, for its
    /// details link and required flag.
    func deduplicatedLatest() -> [CheckRun] {
        var best: [CheckRunDedupeKey: CheckRun] = [:]
        var order: [CheckRunDedupeKey] = []
        for run in self {
            let key = CheckRunDedupeKey(name: run.name, workflowRunID: run.workflowRunID)
            if let existing = best[key] {
                if Self.replaces(run, existing) {
                    best[key] = run
                }
            } else {
                order.append(key)
                best[key] = run
            }
        }
        return order.compactMap { best[$0] }
    }

    private static func replaces(_ candidate: CheckRun, _ current: CheckRun) -> Bool {
        if candidate.isCommitStatus != current.isCommitStatus {
            return !candidate.isCommitStatus
        }
        return isLater(candidate, than: current)
    }

    private static func isLater(_ candidate: CheckRun, than current: CheckRun) -> Bool {
        switch (candidate.startedAt, current.startedAt) {
        case let (.some(a), .some(b)) where a != b:
            return a > b
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return candidate.conclusionPriority > current.conclusionPriority
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

    var iconTint: StatusTint {
        switch self {
        case .success: return .green
        case .failure, .startupFailure, .timedOut: return .red
        case .cancelled, .stale: return .gray
        case .neutral, .skipped: return .gray
        case .actionRequired: return .yellow
        }
    }
}
