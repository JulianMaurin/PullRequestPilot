import Foundation

struct DashboardView: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var query: String

    static let defaultViews: [DashboardView] = [
        DashboardView(
            id: UUID(),
            title: "Review Requests",
            query: "is:pr is:open review-requested:@me archived:false"
        )
    ]
}
