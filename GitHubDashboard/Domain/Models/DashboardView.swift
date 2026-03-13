import Foundation

struct DashboardView: Identifiable, Codable, Hashable {
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

    static let defaultViews: [DashboardView] = [
        DashboardView(
            id: UUID(),
            title: "Review Requests",
            query: "is:pr is:open review-requested:@me archived:false",
            hideReviewed: true
        )
    ]
}
