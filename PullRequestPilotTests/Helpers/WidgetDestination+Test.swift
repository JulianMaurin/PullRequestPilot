import Foundation
@testable import PullRequestPilot

extension WidgetDestination {
    /// A fresh file under the temporary directory; timeline reloads are ignored.
    static func temporary() -> WidgetDestination {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("widget-data-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("widget-data.json")
        return WidgetDestination(fileURL: fileURL, reloadTimelines: {})
    }
}
