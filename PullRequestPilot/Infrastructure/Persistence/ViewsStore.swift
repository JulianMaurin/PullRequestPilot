import Foundation
import os

// MARK: - Protocol

@MainActor
protocol ViewsStoreProtocol {
    func load() -> [DashboardView]
    func save(_ views: [DashboardView])
    var loadError: String? { get }
}

// MARK: - Implementation

@MainActor
@Observable
final class ViewsStore: ViewsStoreProtocol {
    private static let key = "dashboard_views"
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PullRequestPilot", category: "ViewsStore")
    private(set) var loadError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [DashboardView] {
        guard let data = defaults.data(forKey: Self.key) else {
            loadError = nil
            return DashboardView.defaultViews
        }
        do {
            let views = try JSONDecoder().decode([DashboardView].self, from: data)
            loadError = nil
            return views.isEmpty ? DashboardView.defaultViews : views
        } catch {
            logger.error("Failed to decode saved views: \(error, privacy: .public)")
            loadError = "Your saved views could not be loaded and were reset. This may happen after an app update."
            return DashboardView.defaultViews
        }
    }

    func save(_ views: [DashboardView]) {
        do {
            let data = try JSONEncoder().encode(views)
            defaults.set(data, forKey: Self.key)
            loadError = nil
        } catch {
            logger.error("Failed to encode views for saving: \(error, privacy: .public)")
        }
    }
}
