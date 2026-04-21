import Foundation
@testable import PullRequestPilot

actor MockLogEntrySource: LogEntrySource {
    private var entries: [LogEntry]
    private var errorToThrow: Error?

    init(entries: [LogEntry] = [], errorToThrow: Error? = nil) {
        self.entries = entries
        self.errorToThrow = errorToThrow
    }

    func setEntries(_ entries: [LogEntry]) { self.entries = entries }
    func setError(_ error: Error?) { self.errorToThrow = error }

    func currentProcessEntries(subsystem: String) async throws -> [LogEntry] {
        if let err = errorToThrow { throw err }
        return entries
    }
}

actor MockPasteboard: PasteboardWriting {
    private(set) var writes: [String] = []
    private var shouldSucceed: Bool

    init(shouldSucceed: Bool = true) { self.shouldSucceed = shouldSucceed }

    func setShouldSucceed(_ value: Bool) { shouldSucceed = value }
    func recordedWrites() -> [String] { writes }

    func setString(_ value: String) async -> Bool {
        writes.append(value)
        return shouldSucceed
    }
}

actor MockWorkspace: WorkspaceOpening {
    private(set) var opened: [URL] = []
    private(set) var revealed: [URL] = []
    private var openShouldSucceed: Bool
    private var consoleURL: URL?

    init(
        openShouldSucceed: Bool = true,
        consoleURL: URL? = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
    ) {
        self.openShouldSucceed = openShouldSucceed
        self.consoleURL = consoleURL
    }

    func setOpenShouldSucceed(_ value: Bool) { openShouldSucceed = value }
    func setConsoleURL(_ url: URL?) { consoleURL = url }
    func recordedOpens() -> [URL] { opened }
    func recordedReveals() -> [URL] { revealed }

    func open(_ url: URL) async -> Bool {
        opened.append(url)
        return openShouldSucceed
    }

    func revealInFinder(_ url: URL) async {
        revealed.append(url)
    }

    func consoleAppURL() async -> URL? {
        consoleURL
    }
}

/// Test-only sink for `EventReporter` posts. Lives on the main actor so tests
/// can read `events` synchronously without polling.
@MainActor
final class EventRecorder {
    private(set) var events: [AppEvent] = []

    func reporter() -> EventReporter {
        EventReporter { [weak self] event in
            MainActor.assumeIsolated {
                self?.events.append(event)
            }
        }
    }
}
