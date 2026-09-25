import Foundation
import os

extension Logger {
    /// The bundle identifier. Export Logs and the Console predicate filter on
    /// it, so a logger under any other subsystem is missing from support bundles.
    static let appSubsystem = Bundle.main.bundleIdentifier ?? "com.pullrequestpilot.app"

    init(category: String) {
        self.init(subsystem: Self.appSubsystem, category: category)
    }
}
