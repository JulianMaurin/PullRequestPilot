import Foundation

struct WidgetViewData: Codable, Sendable {
    let id: String
    let title: String
    let count: Int
}

struct WidgetData: Codable, Sendable {
    let views: [WidgetViewData]
    let lastUpdated: Date

    private static var sharedFileURL: URL {
        let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Constants.App.appGroupIdentifier
        )!
        return container.appendingPathComponent("widget-data.json")
    }

    static func load() -> WidgetData? {
        let url = sharedFileURL
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetData.self, from: data)
    }

    func save() {
        let url = Self.sharedFileURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
