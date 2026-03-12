import Foundation

final class ViewsStore: @unchecked Sendable {
    private static let key = "dashboard_views"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [DashboardView] {
        guard let data = defaults.data(forKey: Self.key),
              let views = try? JSONDecoder().decode([DashboardView].self, from: data),
              !views.isEmpty else {
            return DashboardView.defaultViews
        }
        return views
    }

    func save(_ views: [DashboardView]) {
        guard let data = try? JSONEncoder().encode(views) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
