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
    let reviewDecision: ReviewDecision?
    let checkStatus: CheckStatus?
    let isDraft: Bool
    let state: PullRequestState?

    var compactAge: String {
        PullRequestAge.compact(since: createdAt, relativeTo: .now)
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

    /// Pull requests the view has but the widget data leaves out.
    var omittedPullRequestCount: Int {
        max(0, count - pullRequests.count)
    }

    var deepLinkURL: URL? {
        DeepLink.viewURL(viewID: id)
    }
}

// MARK: - Container

struct WidgetData: Codable, Sendable {
    let views: [WidgetViewData]
    let lastUpdated: Date

    static let appGroupIdentifier = "FNR3B372S8.com.pullrequestpilot.shared"
    private static let logger = Logger(category: "WidgetData")

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

    /// The file the app writes and the widget reads, in the shared app-group
    /// container. nil when the container is unavailable.
    static var appGroupFileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent("widget-data.json")
    }

    static func load() -> WidgetData? {
        guard let url = appGroupFileURL else {
            logger.error("App-group container unavailable; no widget data to read")
            return nil
        }
        return load(from: url)
    }

    static func load(from url: URL) -> WidgetData? {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try decoder.decode(WidgetData.self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // Expected before the app's first save, but also what a widget
            // sees if the app can never write: keep it in the exported logs.
            logger.notice("Widget data file not found; the app hasn't written it yet: \(error, privacy: .public)")
            return nil
        } catch {
            logger.error("Failed to load widget data: \(error, privacy: .public)")
            return nil
        }
    }

    func save(to url: URL) {
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
