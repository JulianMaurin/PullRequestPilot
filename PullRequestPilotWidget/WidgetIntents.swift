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

        let lines = view.pullRequests.map { "- #\($0.number): \($0.title)" }
        let text = lines.joined(separator: "\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        return .result()
    }
}

// MARK: - Open All PRs

struct OpenAllPRsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open All PRs"
    static let description = IntentDescription("Opens all pull requests from a view in the browser.")

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

        for pr in view.pullRequests {
            NSWorkspace.shared.open(pr.url)
        }

        return .result()
    }
}
