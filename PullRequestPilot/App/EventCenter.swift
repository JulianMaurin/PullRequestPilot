import Foundation
import os

// MARK: - EventReporter

/// Write-only view onto `EventCenter`. Layers that shouldn't be able to read
/// or dismiss events (stores, non-UI services) hold this instead of the full
/// center. Sendable so it can cross actor boundaries.
struct EventReporter: Sendable {
    private let _post: @Sendable (AppEvent) -> Void

    init(post: @escaping @Sendable (AppEvent) -> Void) {
        self._post = post
    }

    func post(_ event: AppEvent) { _post(event) }
    func postError(_ error: AppError) { _post(.error(error)) }
    func postInfo(_ text: String) { _post(.info(text)) }
    func postWarning(_ text: String) { _post(.warning(text)) }

    /// A no-op reporter — used in tests or contexts where no user surface exists.
    static let noop = EventReporter(post: { _ in })
}

// MARK: - EventCenter

/// App-wide bus for user-visible events. One instance lives in `AppState` and
/// is injected (directly or via `EventReporter`) into every layer that can
/// fail in a way the user should know about.
@MainActor
@Observable
final class EventCenter {
    /// Most recent events first. Bounded to `maxHistory` entries.
    private(set) var events: [AppEvent] = []

    /// The entries rendered by the toast overlay (not yet dismissed).
    var activeEvents: [AppEvent] { events.filter { !dismissed.contains($0.id) } }

    /// Full log for the Settings diagnostics panel, bounded to `maxHistory`.
    var history: [AppEvent] { events }

    private var dismissed: Set<UUID> = []
    private var dedupeWindow: [DedupeKey: Date] = [:]
    private var autoDismissTasks: [UUID: Task<Void, Never>] = [:]
    private let maxHistory: Int
    private let clock: any Clock<Duration>
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PullRequestPilot", category: "EventCenter")

    init(maxHistory: Int = 50, clock: any Clock<Duration> = ContinuousClock()) {
        self.maxHistory = maxHistory
        self.clock = clock
    }

    // MARK: - Public API

    /// Post an event. Identical events within a short window are deduped to
    /// avoid toast fatigue when a failing subsystem retries in a tight loop.
    func post(_ event: AppEvent) {
        if shouldSuppressDuplicate(event) { return }

        events.insert(event, at: 0)
        if events.count > maxHistory {
            let overflow = events.count - maxHistory
            let dropped = Array(events.suffix(overflow))
            events.removeLast(overflow)
            for e in dropped { autoDismissTasks.removeValue(forKey: e.id)?.cancel() }
        }

        logEvent(event)

        if let duration = event.autoDismissAfter {
            scheduleAutoDismiss(id: event.id, after: duration)
        }
    }

    func dismiss(_ id: UUID) {
        dismissed.insert(id)
        autoDismissTasks.removeValue(forKey: id)?.cancel()
    }

    /// Dismiss every error with this exact case (ignoring associated values).
    /// Used when a subsystem recovers and wants to clear its prior banner.
    func dismissAll(matching match: (AppError) -> Bool) {
        for event in events {
            if case .error(let err) = event.payload, match(err) {
                dismissed.insert(event.id)
                autoDismissTasks.removeValue(forKey: event.id)?.cancel()
            }
        }
    }

    func clearHistory() {
        events.removeAll()
        dismissed.removeAll()
        for (_, task) in autoDismissTasks { task.cancel() }
        autoDismissTasks.removeAll()
    }

    /// Write-only view for layers that post but never read.
    func reporter() -> EventReporter {
        EventReporter { [weak self] event in
            guard let self else { return }
            Task { @MainActor in self.post(event) }
        }
    }

    // MARK: - Private

    private func scheduleAutoDismiss(id: UUID, after duration: Duration) {
        let clock = self.clock
        let task = Task { @MainActor [weak self] in
            try? await clock.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.dismiss(id)
            self?.autoDismissTasks.removeValue(forKey: id)
        }
        autoDismissTasks[id] = task
    }

    private func logEvent(_ event: AppEvent) {
        switch event.payload {
        case .error(let error):
            logger.error("event: \(error.errorDescription ?? "unknown", privacy: .public)")
        case .warning(let text):
            logger.warning("event: \(text, privacy: .public)")
        case .info(let text):
            logger.info("event: \(text, privacy: .public)")
        }
    }

    // MARK: - Dedupe

    /// Squash repeat posts of the same payload inside a 3-second window.
    private func shouldSuppressDuplicate(_ event: AppEvent) -> Bool {
        let key = DedupeKey(payload: event.payload)
        let now = Date.now
        if let last = dedupeWindow[key], now.timeIntervalSince(last) < 3 {
            return true
        }
        dedupeWindow[key] = now
        // Opportunistic cleanup
        dedupeWindow = dedupeWindow.filter { now.timeIntervalSince($0.value) < 30 }
        return false
    }

    private struct DedupeKey: Hashable {
        let discriminator: String

        init(payload: AppEvent.Payload) {
            switch payload {
            case .error(let err): self.discriminator = "error:" + String(describing: err)
            case .warning(let text): self.discriminator = "warning:" + text
            case .info(let text): self.discriminator = "info:" + text
            }
        }
    }
}
