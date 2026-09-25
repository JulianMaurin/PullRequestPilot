import AppKit
import Foundation
import os

/// An app that can open a pull request's local checkout.
enum ExternalEditor: CaseIterable, Identifiable, Sendable {
    case visualStudioCode
    case iTerm
    case cmux

    var id: Self { self }

    var displayName: String {
        switch self {
        case .visualStudioCode: "VS Code"
        case .iTerm: "iTerm"
        case .cmux: "cmux"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .visualStudioCode: "com.microsoft.VSCode"
        case .iTerm: "com.googlecode.iterm2"
        case .cmux: "com.cmuxterm.app"
        }
    }
}

/// Finds the editors installed on this Mac and opens a directory in one.
@MainActor
final class ExternalEditorLauncher {
    typealias ApplicationLocator = @MainActor (_ bundleIdentifier: String) -> URL?
    typealias DirectoryOpener = @MainActor (_ directory: URL, _ application: URL) async throws -> Void

    private let reporter: EventReporter
    private let locateApplication: ApplicationLocator
    private let openDirectory: DirectoryOpener
    private let logger = Logger(category: "ExternalEditor")

    init(
        reporter: EventReporter = .noop,
        locateApplication: @escaping ApplicationLocator = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
        openDirectory: @escaping DirectoryOpener = ExternalEditorLauncher.openWithWorkspace
    ) {
        self.reporter = reporter
        self.locateApplication = locateApplication
        self.openDirectory = openDirectory
    }

    /// In menu order.
    var installedEditors: [ExternalEditor] {
        ExternalEditor.allCases.filter { locateApplication($0.bundleIdentifier) != nil }
    }

    func open(_ directory: URL, in editor: ExternalEditor) async {
        guard let application = locateApplication(editor.bundleIdentifier) else {
            logger.error("Application not found: \(editor.displayName, privacy: .public)")
            reporter.postError(.externalAppLaunchFailed(appName: editor.displayName))
            return
        }
        do {
            try await openDirectory(directory, application)
        } catch {
            logger.error("Failed to open \(editor.displayName, privacy: .public): \(error, privacy: .public)")
            reporter.postError(.externalAppLaunchFailed(appName: editor.displayName))
        }
    }

    static func openWithWorkspace(_ directory: URL, _ application: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open([directory], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
