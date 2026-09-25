import AppIntents
import AppKit

// MARK: - Copy PR List

struct CopyPRListIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy PR List"
    static let description = IntentDescription("Copies a formatted list of pull requests to the clipboard.")

    @Parameter(title: "View ID")
    var viewID: String

    init() {}

    init(viewID: String) {
        self.viewID = viewID
    }

    func perform() async throws -> some IntentResult {
        guard let data = WidgetData.load(),
              let view = data.views.first(where: { $0.id == viewID })
        else {
            return .result()
        }

        guard !view.pullRequests.isEmpty else {
            return .result()
        }

        var lines = view.pullRequests.map { "- \($0.url.absoluteString): \($0.title)" }
        // The widget keeps the first pull requests only; say what's left out.
        if view.omittedPullRequestCount > 0 {
            lines.append("- … and \(view.omittedPullRequestCount) more in Pull Request Pilot")
        }
        let text = lines.joined(separator: "\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        return .result()
    }
}

// MARK: - Open All PRs

struct OpenAllPRsIntent: AppIntent {
    /// Keeps a large view from flooding the browser with tabs.
    static let maximumOpened = 10

    static let title: LocalizedStringResource = "Open PRs in Browser"
    static let description = IntentDescription("Opens up to 10 of a view's pull requests in the browser.")

    @Parameter(title: "View ID")
    var viewID: String

    init() {}

    init(viewID: String) {
        self.viewID = viewID
    }

    func perform() async throws -> some IntentResult {
        guard let data = WidgetData.load(),
              let view = data.views.first(where: { $0.id == viewID })
        else {
            return .result()
        }

        for pr in view.pullRequests.prefix(Self.maximumOpened) {
            NSWorkspace.shared.open(pr.url)
        }

        return .result()
    }
}
