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
    private let reporter: EventReporter
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PullRequestPilot", category: "ViewsStore")

    /// Kept for backward compatibility with existing tests/UI. Populated alongside
    /// the EventCenter post so either surface can read it.
    private(set) var loadError: String?

    init(defaults: UserDefaults = .standard, reporter: EventReporter = .noop) {
        self.defaults = defaults
        self.reporter = reporter
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
            let backupPath = backupCorruptedData(data)
            logger.error("Failed to decode saved views: \(error, privacy: .public). Backup: \(backupPath ?? "n/a", privacy: .public)")
            loadError = "Your saved views could not be loaded and were reset. A backup was saved."
            reporter.postError(.decodeCorruption(subsystem: "dashboard views", backupPath: backupPath))
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
            reporter.postError(.decodeCorruption(subsystem: "dashboard views", backupPath: nil))
        }
    }

    // MARK: - Corruption Backup

    /// Write the raw bytes of the failed-to-decode blob to Application Support
    /// so the user can recover manually if needed. Filename includes the
    /// calendar date so repeated failures on the same day overwrite rather than
    /// fill the disk.
    private func backupCorruptedData(_ data: Data) -> String? {
        guard let supportDir = Self.applicationSupportDirectory() else { return nil }
        let filename = "dashboard-views.corrupted-\(Self.backupDateString()).json"
        let url = supportDir.appendingPathComponent(filename)
        do {
            try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url.path
        } catch {
            logger.error("Failed to write corruption backup: \(error, privacy: .public)")
            return nil
        }
    }

    static func applicationSupportDirectory() -> URL? {
        let bundleID = Bundle.main.bundleIdentifier ?? "PullRequestPilot"
        let base: URL
        do {
            base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            Logger(subsystem: bundleID, category: "ViewsStore")
                .error("Application Support directory unavailable: \(error, privacy: .public)")
            return nil
        }
        return base.appendingPathComponent(bundleID, isDirectory: true)
    }

    private static let backupDateFormatterLock = NSLock()
    private static let backupDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func backupDateString(for date: Date = .now) -> String {
        backupDateFormatterLock.lock()
        defer { backupDateFormatterLock.unlock() }
        return backupDateFormatter.string(from: date)
    }
}
