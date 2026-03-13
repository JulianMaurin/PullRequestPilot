import Foundation

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
    let pullRequests: [WidgetPullRequest]

    var approvedCount: Int {
        pullRequests.filter { $0.reviewDecision == "APPROVED" }.count
    }

    var changesRequestedCount: Int {
        pullRequests.filter { $0.reviewDecision == "CHANGES_REQUESTED" }.count
    }

    var pendingReviewCount: Int {
        count - approvedCount - changesRequestedCount
    }
}

// MARK: - Container

struct WidgetData: Codable, Sendable {
    let views: [WidgetViewData]
    let lastUpdated: Date

    private static let appGroupIdentifier = "FNR3B372S8.com.pullrequestpilot.shared"

    private static var sharedFileURL: URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else { return nil }
        return container.appendingPathComponent("widget-data.json")
    }

    static func load() -> WidgetData? {
        guard let url = sharedFileURL else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WidgetData.self, from: data)
    }

    func save() {
        guard let url = Self.sharedFileURL else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
