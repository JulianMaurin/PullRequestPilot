import Foundation

struct WidgetViewData: Codable, Sendable {
    let id: String
    let title: String
    let count: Int
}

struct WidgetData: Codable, Sendable {
    let views: [WidgetViewData]
    let lastUpdated: Date

    private static var sharedFileURL: URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Constants.App.appGroupIdentifier
        ) else { return nil }
        return container.appendingPathComponent("widget-data.json")
    }

    static func load() -> WidgetData? {
        guard let url = sharedFileURL else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetData.self, from: data)
    }

    func save() {
        guard let url = Self.sharedFileURL else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
