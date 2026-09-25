import Foundation
import os

// MARK: - EventReporter

/// Write-only view onto `EventCenter`. Layers that shouldn't be able to read
/// or dismiss events (stores, non-UI services) hold this instead of the full
/// center. Sendable so it can cross actor boundaries.
struct EventReporter: Sendable {
    typealias ErrorMatch = @Sendable (AppError) -> Bool

    private let _post: @Sendable (AppEvent) -> Void
    private let _resolve: @Sendable (@escaping ErrorMatch) -> Void

    init(post: @escaping @Sendable (AppEvent) -> Void, resolve: @escaping @Sendable (@escaping ErrorMatch) -> Void = { _ in }) {
        self._post = post
        self._resolve = resolve
    }

    func post(_ event: AppEvent) { _post(event) }
    func postError(_ error: AppError) { _post(.error(error)) }
    func postInfo(_ text: String) { _post(.info(text)) }
    func postWarning(_ text: String) { _post(.warning(text)) }

    /// The subsystem recovered: clears matching errors from every surface,
    /// including the standing banner.
    func resolve(matching match: @escaping ErrorMatch) { _resolve(match) }

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

    /// The entries rendered by the toast overlay: neither explicitly
    /// dismissed nor timed out.
    var activeEvents: [AppEvent] { events.filter { !dismissed.contains($0.id) && !autoDismissed.contains($0.id) } }

    /// The entries rendered by inline banners: standing errors
    /// (`AppError.isStanding`) that are neither dismissed nor resolved. A timed
    /// toast expiry hides the toast only.
    var standingEvents: [AppEvent] {
        events.filter { !dismissed.contains($0.id) && $0.appError?.isStanding == true }
    }

    /// IDs hidden everywhere (user dismissal or subsystem recovery).
    /// Invariant: always a subset of `events`' IDs — pruned when overflow
    /// drops events — so it stays bounded to `maxHistory`.
    private(set) var dismissed: Set<UUID> = []

    /// IDs whose auto-dismiss timer fired: hidden from toasts, still standing
    /// for banners. Same bounding invariant as `dismissed`.
    private(set) var autoDismissed: Set<UUID> = []
    /// Lock-backed so deinit can cancel tasks without hopping to MainActor.
    private let autoDismissTasksStorage = OSAllocatedUnfairLock<[UUID: Task<Void, Never>]>(initialState: [:])
    private let maxHistory: Int
    private let clock: any Clock<Duration>
    private let logger = Logger(category: "EventCenter")

    init(maxHistory: Int = 50, clock: any Clock<Duration> = ContinuousClock()) {
        self.maxHistory = maxHistory
        self.clock = clock
    }

    deinit {
        autoDismissTasksStorage.withLock { tasks in
            tasks.values.forEach { $0.cancel() }
            tasks.removeAll()
        }
    }

    // MARK: - Public API

    /// Post an event. If a matching payload is already standing (not
    /// explicitly dismissed), re-surface that event's toast and refresh its
    /// timer instead of inserting a copy. This keeps the UI to one event per
    /// ongoing problem while still logging every occurrence for incident
    /// timelines.
    func post(_ event: AppEvent) {
        logEvent(event)

        if let index = events.firstIndex(where: { existing in
            !dismissed.contains(existing.id) && existing.payload.describesSameCondition(as: event.payload)
        }) {
            let existing = events[index]
            // Keep the identity, take the newest details (e.g. a later reset time).
            events[index] = AppEvent(
                id: existing.id,
                payload: event.payload,
                postedAt: existing.postedAt,
                autoDismissAfter: existing.autoDismissAfter
            )
            // A recurrence re-shows the toast if it had timed out.
            autoDismissed.remove(existing.id)
            if let duration = existing.autoDismissAfter {
                scheduleAutoDismiss(id: existing.id, after: duration)
            }
            return
        }

        events.insert(event, at: 0)
        if events.count > maxHistory {
            let overflow = events.count - maxHistory
            let dropped = Array(events.suffix(overflow))
            events.removeLast(overflow)
            dismissed.subtract(dropped.map(\.id))
            autoDismissed.subtract(dropped.map(\.id))
            autoDismissTasksStorage.withLock { tasks in
                for e in dropped { tasks.removeValue(forKey: e.id)?.cancel() }
            }
        }

        if let duration = event.autoDismissAfter {
            scheduleAutoDismiss(id: event.id, after: duration)
        }
    }

    func dismiss(_ id: UUID) {
        // Only track IDs still in history — a late auto-dismiss firing for an
        // event that overflow already dropped must not re-grow `dismissed`.
        if events.contains(where: { $0.id == id }) {
            dismissed.insert(id)
            autoDismissed.remove(id)
        }
        autoDismissTasksStorage.withLock { tasks in
            tasks.removeValue(forKey: id)?.cancel()
        }
    }

    /// Cancel the auto-dismiss timer for `id` so the toast stays visible.
    /// Paired with `resumeAutoDismiss(_:)` — used by the toast overlay to
    /// pause dismissal while the user hovers.
    func pauseAutoDismiss(_ id: UUID) {
        autoDismissTasksStorage.withLock { tasks in
            tasks.removeValue(forKey: id)?.cancel()
        }
    }

    /// Reschedule the auto-dismiss timer for `id` using the event's original
    /// `autoDismissAfter` duration. No-op when the event has no duration, is
    /// already dismissed or timed out, or no longer exists in history.
    func resumeAutoDismiss(_ id: UUID) {
        guard !dismissed.contains(id),
              !autoDismissed.contains(id),
              let event = events.first(where: { $0.id == id }),
              let duration = event.autoDismissAfter
        else { return }
        scheduleAutoDismiss(id: id, after: duration)
    }

    /// Dismiss every error the predicate matches. Used when a subsystem
    /// recovers and wants to clear its prior toast and banner.
    func dismissAll(matching match: (AppError) -> Bool) {
        for event in events where !dismissed.contains(event.id) {
            if case .error(let err) = event.payload, match(err) {
                dismissed.insert(event.id)
                autoDismissed.remove(event.id)
                autoDismissTasksStorage.withLock { tasks in
                    tasks.removeValue(forKey: event.id)?.cancel()
                }
            }
        }
    }

    /// Write-only view for layers that post but never read.
    func reporter() -> EventReporter {
        EventReporter(
            post: { [weak self] event in
                guard let self else { return }
                Task { @MainActor in self.post(event) }
            },
            resolve: { [weak self] match in
                guard let self else { return }
                Task { @MainActor in self.dismissAll(matching: match) }
            }
        )
    }

    // MARK: - Private

    private func scheduleAutoDismiss(id: UUID, after duration: Duration) {
        let clock = self.clock
        let task = Task { @MainActor [weak self] in
            do {
                try await clock.sleep(for: duration)
            } catch {
                return
            }
            self?.expireToast(id)
        }
        autoDismissTasksStorage.withLock { tasks in
            tasks.updateValue(task, forKey: id)?.cancel()
        }
    }

    /// Timer expiry: hide the toast, keep the event standing for banners.
    private func expireToast(_ id: UUID) {
        if events.contains(where: { $0.id == id }) {
            autoDismissed.insert(id)
        }
        autoDismissTasksStorage.withLock { tasks in
            _ = tasks.removeValue(forKey: id)
        }
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

}
