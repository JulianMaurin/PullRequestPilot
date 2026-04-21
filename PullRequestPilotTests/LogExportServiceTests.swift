import Foundation
import Testing
@testable import PullRequestPilot

@Suite("LogExportService.exportLogs")
struct LogExportServiceExportTests {

    @Test("writes a file containing header and formatted entries")
    @MainActor
    func exportsEntriesToFile() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let entry = LogEntry(
            date: Date(timeIntervalSince1970: 1_713_700_000),
            level: .error,
            category: "EventCenter",
            message: "event: boom"
        )
        let store = MockLogEntrySource(entries: [entry])
        let workspace = MockWorkspace()
        let recorder = EventRecorder()

        let service = LogExportService(
            reporter: recorder.reporter(),
            store: store,
            pasteboard: MockPasteboard(),
            workspace: workspace,
            tempDirectory: tmp,
            bundleID: "com.test.app",
            appVersion: "1.2.3",
            appBuild: "45",
            osVersion: "macOS 14.4"
        )

        await service.exportLogs()

        let files = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
        let logFile = try #require(files.first)
        let contents = try String(contentsOf: logFile, encoding: .utf8)

        #expect(contents.contains("Pull Request Pilot — log export"))
        #expect(contents.contains("App version: 1.2.3 (45)"))
        #expect(contents.contains("macOS: macOS 14.4"))
        #expect(contents.contains("Subsystem: com.test.app"))
        #expect(contents.contains("[error] [EventCenter] event: boom"))

        let reveals = await workspace.recordedReveals()
        #expect(reveals == [logFile])

        #expect(recorder.events.count == 1)
        if case .info(let text) = recorder.events.first?.payload {
            #expect(text == "Logs saved — revealed in Finder.")
        } else {
            Issue.record("Expected info event, got \(String(describing: recorder.events.first))")
        }
    }

    @Test("writes header + no-entries message when store is empty")
    @MainActor
    func exportsEmptyRun() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = MockLogEntrySource(entries: [])
        let recorder = EventRecorder()

        let service = LogExportService(
            reporter: recorder.reporter(),
            store: store,
            pasteboard: MockPasteboard(),
            workspace: MockWorkspace(),
            tempDirectory: tmp,
            bundleID: "com.test.app",
            appVersion: "1.0.0",
            appBuild: "1",
            osVersion: "macOS 14.4"
        )

        await service.exportLogs()

        let files = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
        let logFile = try #require(files.first)
        let contents = try String(contentsOf: logFile, encoding: .utf8)

        #expect(contents.contains("No log entries were recorded during this app run."))
        #expect(recorder.events.count == 1)
        if case .error = recorder.events.first?.payload {
            Issue.record("Empty run should not post an error event.")
        }
    }

    @Test("posts logExportFailed when the store throws")
    @MainActor
    func exportsSurfaceStoreErrors() async throws {
        struct BoomError: Error, LocalizedError {
            var errorDescription: String? { "boom" }
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = MockLogEntrySource(entries: [], errorToThrow: BoomError())
        let recorder = EventRecorder()

        let service = LogExportService(
            reporter: recorder.reporter(),
            store: store,
            pasteboard: MockPasteboard(),
            workspace: MockWorkspace(),
            tempDirectory: tmp,
            bundleID: "com.test.app",
            appVersion: "1.0.0",
            appBuild: "1",
            osVersion: "macOS 14.4"
        )

        await service.exportLogs()

        let files = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
        #expect(files.isEmpty)

        #expect(recorder.events.count == 1)
        if case .error(.logExportFailed(let underlying)) = recorder.events.first?.payload {
            #expect(underlying == "boom")
        } else {
            Issue.record("Expected .logExportFailed, got \(String(describing: recorder.events.first))")
        }
    }
}

@Suite("LogExportService.openConsole")
struct LogExportServiceOpenConsoleTests {

    @Test("copies subsystem predicate, launches Console, posts info toast")
    @MainActor
    func opensConsoleWithFilter() async throws {
        let pasteboard = MockPasteboard()
        let consoleURL = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        let workspace = MockWorkspace(openShouldSucceed: true, consoleURL: consoleURL)
        let recorder = EventRecorder()

        let service = LogExportService(
            reporter: recorder.reporter(),
            store: MockLogEntrySource(),
            pasteboard: pasteboard,
            workspace: workspace,
            tempDirectory: FileManager.default.temporaryDirectory,
            bundleID: "com.test.app",
            appVersion: "1.0.0",
            appBuild: "1",
            osVersion: "macOS 14.4"
        )

        await service.openConsole()

        let writes = await pasteboard.recordedWrites()
        #expect(writes == ["subsystem == \"com.test.app\""])

        let opens = await workspace.recordedOpens()
        #expect(opens == [consoleURL])

        #expect(recorder.events.count == 1)
        if case .info(let text) = recorder.events.first?.payload {
            #expect(text == "Filter copied — paste into Console's search field.")
        } else {
            Issue.record("Expected info event, got \(String(describing: recorder.events.first))")
        }
    }
}
