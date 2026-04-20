import Foundation
import os

// MARK: - Widget PR Model

struct WidgetPullRequest: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let repositoryName: String
    let authorLogin: String
    let createdAt: Date
    let reviewDecision: String?
    let checkStatus: String?
    let isDraft: Bool
    let state: String?

    var compactAge: String {
        let interval = Date.now.timeIntervalSince(createdAt)
        let minutes = Int(interval / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        if days < 30 { return "\(days)d" }
        let months = days / 30
        return "\(months)mo"
    }

    var repoShortName: String {
        String(repositoryName.split(separator: "/").last ?? Substring(repositoryName))
    }
}

// MARK: - Widget View Model

struct WidgetViewData: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let title: String
    let count: Int
    let approvedCount: Int
    let changesRequestedCount: Int
    let pullRequests: [WidgetPullRequest]

    var pendingReviewCount: Int {
        max(0, count - approvedCount - changesRequestedCount)
    }
}

// MARK: - Container

struct WidgetData: Codable, Sendable {
    let views: [WidgetViewData]
    let lastUpdated: Date

    static let appGroupIdentifier = "FNR3B372S8.com.pullrequestpilot.shared"
    private static let logger = Logger(subsystem: "PullRequestPilot", category: "WidgetData")

    /// Set by the main app at launch to route save failures into the user-visible
    /// EventCenter. The widget extension leaves this nil — widgets have no toast
    /// surface, so load/save failures there are logged only.
    private static let errorReporterStorage = OSAllocatedUnfairLock<(@Sendable (String) -> Void)?>(initialState: nil)

    static func setErrorReporter(_ reporter: (@Sendable (String) -> Void)?) {
        errorReporterStorage.withLock { $0 = reporter }
    }

    private static var errorReporter: (@Sendable (String) -> Void)? {
        errorReporterStorage.withLock { $0 }
    }

    private static var sharedFileURL: URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else { return nil }
        return container.appendingPathComponent("widget-data.json")
    }

    static func load() -> WidgetData? {
        guard let url = sharedFileURL else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try decoder.decode(WidgetData.self, from: data)
        } catch {
            logger.debug("Failed to load widget data: \(error, privacy: .public)")
            return nil
        }
    }

    func save() {
        guard let url = Self.sharedFileURL else { return }
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            let data = try encoder.encode(self)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.error("Failed to save widget data: \(error, privacy: .public)")
            Self.errorReporter?(error.localizedDescription)
        }
    }
}
