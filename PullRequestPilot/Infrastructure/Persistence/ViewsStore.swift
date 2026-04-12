import Foundation
import os

final class ViewsStore: @unchecked Sendable {
    private static let key = "dashboard_views"
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PullRequestPilot", category: "ViewsStore")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [DashboardView] {
        guard let data = defaults.data(forKey: Self.key) else {
            return DashboardView.defaultViews
        }
        do {
            let views = try JSONDecoder().decode([DashboardView].self, from: data)
            return views.isEmpty ? DashboardView.defaultViews : views
        } catch {
            logger.error("Failed to decode saved views: \(error, privacy: .public)")
            return DashboardView.defaultViews
        }
    }

    func save(_ views: [DashboardView]) {
        do {
            let data = try JSONEncoder().encode(views)
            defaults.set(data, forKey: Self.key)
        } catch {
            logger.error("Failed to encode views for saving: \(error, privacy: .public)")
        }
    }
}
