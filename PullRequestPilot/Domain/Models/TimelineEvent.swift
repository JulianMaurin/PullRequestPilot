import Foundation

struct TimelineEvent: Identifiable, Hashable, Sendable {
    let id: String
    let kind: TimelineEventKind
    let actor: Author?
    let timestamp: Date
    let body: String?

    var label: String {
        let who = actor?.login ?? "someone"
        switch kind {
        case .comment: return "\(who) commented"
        case .review(.approved): return "\(who) approved"
        case .review(.changesRequested): return "\(who) requested changes"
        case .review(.commented): return "\(who) reviewed"
        case .review: return "\(who) reviewed"
        case .merged: return "\(who) merged"
        case .closed: return "\(who) closed"
        case .reopened: return "\(who) reopened"
        case .forcePushed: return "\(who) force pushed"
        case .commit: return "\(who) pushed a commit"
        case .readyForReview: return "\(who) marked ready for review"
        case .convertedToDraft: return "\(who) converted to draft"
        case .assigned(let assignee): return "\(who) assigned \(assignee)"
        case .reviewRequested(let reviewer): return "\(who) requested review from \(reviewer)"
        }
    }

    var iconName: String {
        switch kind {
        case .comment: return "text.bubble"
        case .review(.approved): return "checkmark.circle"
        case .review(.changesRequested): return "xmark.circle"
        case .review: return "eye"
        case .merged: return "arrow.triangle.merge"
        case .closed: return "xmark.circle"
        case .reopened: return "arrow.uturn.left.circle"
        case .forcePushed: return "arrow.up.to.line"
        case .commit: return "smallcircle.filled.circle"
        case .readyForReview: return "eye.circle"
        case .convertedToDraft: return "doc.circle"
        case .assigned: return "person.badge.plus"
        case .reviewRequested: return "person.wave.2"
        }
    }

    var iconColor: String {
        switch kind {
        case .review(.approved): return "green"
        case .review(.changesRequested): return "red"
        case .merged: return "purple"
        case .closed: return "gray"
        case .comment, .review: return "blue"
        default: return "secondary"
        }
    }

    var timestampText: String {
        timestamp.relativeTimestampText(relativeTo: .now)
    }
}

enum TimelineEventKind: Hashable, Sendable {
    case comment
    case review(ReviewState?)
    case merged
    case closed
    case reopened
    case forcePushed
    case commit(message: String?)
    case readyForReview
    case convertedToDraft
    case assigned(assignee: String)
    case reviewRequested(reviewer: String)
}
