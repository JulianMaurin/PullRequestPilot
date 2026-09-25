import Foundation

/// A saved view: a titled GitHub search and its hide-reviewed filter. Data,
/// not a SwiftUI view; the review queue shows one per tab.
struct ViewDefinition: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var query: String
    var hideReviewed: Bool

    // MARK: - Init

    init(id: UUID, title: String, query: String, hideReviewed: Bool = false) {
        self.id = id
        self.title = title
        self.query = query
        self.hideReviewed = hideReviewed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        query = try container.decode(String.self, forKey: .query)
        hideReviewed = try container.decodeIfPresent(Bool.self, forKey: .hideReviewed) ?? false
    }

    // MARK: - Presets

    static let defaultViews: [ViewDefinition] = []

    static let presetViews: [ViewDefinition] = [
        ViewDefinition(
            id: UUID(),
            title: "Needs my review",
            query: "is:open is:pr review-requested:@me draft:false",
            hideReviewed: true
        ),
        ViewDefinition(
            id: UUID(),
            title: "My PRs",
            query: "is:open is:pr author:@me draft:false",
            hideReviewed: false
        ),
        ViewDefinition(
            id: UUID(),
            title: "My drafts",
            query: "is:open is:pr author:@me draft:true",
            hideReviewed: false
        ),
        ViewDefinition(
            id: UUID(),
            title: "Recently merged",
            query: "is:merged is:pr author:@me",
            hideReviewed: false
        ),
    ]
}
