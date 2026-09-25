import Foundation

struct PullRequest: Identifiable, Hashable, Sendable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let repository: Repository
    let author: Author
    let createdAt: Date
    let updatedAt: Date
    let additions: Int
    let deletions: Int
    let state: PullRequestState
    let isDraft: Bool
    let checkStatus: CheckStatus?
    let reviewDecision: ReviewDecision?
    let totalThreads: Int
    let unresolvedThreads: Int
    let labels: [Label]
    let baseRefName: String
    let headRefName: String
    let headCommitSha: String?
    /// Opened from a fork: `headRefName` names a branch in another repository.
    let isCrossRepository: Bool
    let lastActivity: LastActivity?
    let latestReviews: [UserReview]

    var linesChanged: Int { additions + deletions }

    var age: String { age(relativeTo: .now) }

    func age(relativeTo now: Date) -> String {
        PullRequestAge.abbreviated(since: createdAt, relativeTo: now)
    }
}

struct Repository: Hashable, Sendable {
    let nameWithOwner: String

    var owner: String { String(nameWithOwner.split(separator: "/").first ?? "") }
    var name: String { String(nameWithOwner.split(separator: "/").last ?? "") }
}

struct Author: Hashable, Sendable {
    let login: String
    let avatarURL: URL?
    /// A GitHub App account; search qualifies it as `author:app/<login>`.
    let isBot: Bool

    init(login: String, avatarURL: URL?, isBot: Bool = false) {
        self.login = login
        self.avatarURL = avatarURL
        self.isBot = isBot
    }

    /// Value for `author:` qualifiers. A bare login resolves to a user account,
    /// so a GitHub App needs the `app/` prefix to match its pull requests.
    var searchQualifierValue: String {
        isBot ? "app/\(login)" : login
    }
}

struct Label: Hashable, Sendable {
    let name: String
    let color: String
}

// MARK: - User Review

struct UserReview: Hashable, Sendable {
    let login: String
    let state: ReviewState
}

enum ReviewState: String, Sendable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case commented = "COMMENTED"
    case dismissed = "DISMISSED"
    case pending = "PENDING"
}

// MARK: - Last Activity

enum ActivityKind: Hashable, Sendable {
    case comment
    case review(ReviewDecision?)
    case merged
    case closed
    case forcePushed
    case committed

    var iconName: String {
        switch self {
        case .comment: "text.bubble"
        case .review(.approved): "checkmark.circle"
        case .review(.changesRequested): "xmark.circle"
        case .review: "eye"
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle"
        case .forcePushed: "arrow.up.to.line"
        case .committed: "smallcircle.filled.circle"
        }
    }
}

struct LastActivity: Hashable, Sendable {
    let kind: ActivityKind
    let actor: Author?
    let timestamp: Date

    var label: String {
        let who = actor?.login ?? "someone"
        switch kind {
        case .comment: return "comment by \(who)"
        case .review(.approved): return "approved by \(who)"
        case .review(.changesRequested): return "changes requested by \(who)"
        case .review: return "reviewed by \(who)"
        case .merged: return "merged by \(who)"
        case .closed: return "closed by \(who)"
        case .forcePushed: return "force pushed by \(who)"
        case .committed: return "commit by \(who)"
        }
    }

    var timestampText: String { timestampText(relativeTo: .now) }

    func timestampText(relativeTo now: Date) -> String {
        timestamp.relativeTimestampText(relativeTo: now)
    }
}

// MARK: - Shared Timestamp Formatting

extension Date {
    func relativeTimestampText(relativeTo now: Date) -> String {
        let calendar = Calendar.current

        // Future timestamps (server drift, timezone bugs, daylight-savings
        // transitions) should not claim "today at X" for an event that hasn't
        // happened — render as "just now" to avoid misleading the user.
        if self > now {
            return "just now"
        }

        let startOfToday = calendar.startOfDay(for: now)
        let startOfTimestamp = calendar.startOfDay(for: self)
        let dayDifference = calendar.dateComponents([.day], from: startOfTimestamp, to: startOfToday).day ?? 0

        let time = formatted(date: .omitted, time: .shortened)
        if dayDifference <= 0 {
            return "today at \(time)"
        } else if dayDifference == 1 {
            return "yesterday at \(time)"
        } else {
            return "\(formatted(.dateTime.month(.abbreviated).day())) at \(time)"
        }
    }
}
