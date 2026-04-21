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
}
