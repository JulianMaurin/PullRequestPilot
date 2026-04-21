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
        do {
            let entries = try await store.currentProcessEntries(subsystem: bundleID)
            let contents = renderExport(entries: entries)
            let url = try writeExport(contents: contents)
            await workspace.revealInFinder(url)
            reporter.postInfo("Logs saved — revealed in Finder.")
        } catch {
            reporter.postError(.logExportFailed(underlying: error.localizedDescription))
        }
    }

    func openConsole() async {
        let predicate = "subsystem == \"\(bundleID)\""
        _ = await pasteboard.setString(predicate)

        let url = await workspace.consoleAppURL() ?? URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        let opened = await workspace.open(url)
        if !opened {
            reporter.postError(.externalAppLaunchFailed(appName: "Console"))
            return
        }
        reporter.postInfo("Filter copied — paste into Console's search field.")
    }

    // MARK: - Private

    private func renderExport(entries: [LogEntry]) -> String {
        var lines: [String] = []
        lines.append("Pull Request Pilot — log export")
        lines.append("App version: \(appVersion) (\(appBuild))")
        lines.append("macOS: \(osVersion)")
        lines.append("Exported: \(ISO8601DateFormatter().string(from: .now))")
        lines.append("Subsystem: \(bundleID)")
        lines.append("")
        if entries.isEmpty {
            lines.append("No log entries were recorded during this app run.")
        } else {
            let formatter = entryDateFormatter()
            for entry in entries {
                lines.append("\(formatter.string(from: entry.date)) [\(entry.level.rawValue)] [\(entry.category)] \(entry.message)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func writeExport(contents: String) throws -> URL {
        let name = "pull-request-pilot-logs-\(filenameDateFormatter().string(from: .now)).txt"
        let finalURL = tempDirectory.appendingPathComponent(name)
        let stagingURL = tempDirectory.appendingPathComponent(name + ".partial")
        try contents.write(to: stagingURL, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: stagingURL) }
        if fileManager.fileExists(atPath: finalURL.path) {
            try fileManager.removeItem(at: finalURL)
        }
        try fileManager.moveItem(at: stagingURL, to: finalURL)
        return finalURL
    }

    private func entryDateFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }

    private func filenameDateFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }
}
