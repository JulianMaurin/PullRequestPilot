import Foundation

struct DashboardView: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var query: String
    var hideReviewed: Bool

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

    static let defaultViews: [DashboardView] = []

    static let presetViews: [DashboardView] = [
        DashboardView(
            id: UUID(),
            title: "Needs my review",
            query: "is:open is:pr review-requested:@me draft:false base:main",
            hideReviewed: true
        ),
        DashboardView(
            id: UUID(),
            title: "My PRs",
            query: "is:open is:pr author:@me draft:false",
            hideReviewed: false
        ),
        DashboardView(
            id: UUID(),
            title: "My drafts",
            query: "is:open is:pr author:@me draft:true",
            hideReviewed: false
        ),
        DashboardView(
            id: UUID(),
            title: "Recently merged",
            query: "is:merged is:pr author:@me",
            hideReviewed: false
        ),
    ]
}
