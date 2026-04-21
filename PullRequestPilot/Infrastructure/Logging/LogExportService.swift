import AppKit
import Foundation
import OSLog

// MARK: - Dependencies

protocol LogEntrySource: Sendable {
    func currentProcessEntries(subsystem: String) async throws -> [LogEntry]
}

protocol PasteboardWriting: Sendable {
    @discardableResult
    func setString(_ value: String) async -> Bool
}

protocol WorkspaceOpening: Sendable {
    @discardableResult
    func open(_ url: URL) async -> Bool
    func revealInFinder(_ url: URL) async
    func consoleAppURL() async -> URL?
}

// MARK: - LogExportService

@MainActor
final class LogExportService {

    private let reporter: EventReporter
    private let store: any LogEntrySource
    private let pasteboard: any PasteboardWriting
    private let workspace: any WorkspaceOpening
    private let fileManager: FileManager
    private let tempDirectory: URL
    private let bundleID: String
    private let appVersion: String
    private let appBuild: String
    private let osVersion: String

    init(
        reporter: EventReporter,
        store: any LogEntrySource,
        pasteboard: any PasteboardWriting,
        workspace: any WorkspaceOpening,
        fileManager: FileManager = .default,
        tempDirectory: URL = FileManager.default.temporaryDirectory,
        bundleID: String,
        appVersion: String,
        appBuild: String,
        osVersion: String
    ) {
        self.reporter = reporter
        self.store = store
        self.pasteboard = pasteboard
        self.workspace = workspace
        self.fileManager = fileManager
        self.tempDirectory = tempDirectory
        self.bundleID = bundleID
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.osVersion = osVersion
    }

    func exportLogs() async {
        // Implemented in Task 4/5.
    }

    func openConsole() async {
        // Implemented in Task 6/7.
    }
}
