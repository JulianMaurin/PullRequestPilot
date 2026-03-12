import Foundation

struct PullRequest: Identifiable, Hashable {
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
    let isDraft: Bool
    let reviewDecision: ReviewDecision?
    let labels: [Label]
    let baseRefName: String
    let headRefName: String

    var linesChanged: Int { additions + deletions }

    var age: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: createdAt, relativeTo: .now)
    }
}

struct Repository: Hashable {
    let nameWithOwner: String

    var owner: String { String(nameWithOwner.split(separator: "/").first ?? "") }
    var name: String { String(nameWithOwner.split(separator: "/").last ?? "") }
}

struct Author: Hashable {
    let login: String
    let avatarURL: URL?
}

struct Label: Hashable {
    let name: String
    let color: String
}

enum ReviewDecision: String {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case reviewRequired = "REVIEW_REQUIRED"
}
