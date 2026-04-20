import Foundation
import os
import WidgetKit

@MainActor
final class WidgetSync {

    // MARK: - Properties

    private let buildWidgetData: @MainActor () -> WidgetData
    private let throttleInterval: TimeInterval
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PullRequestPilot", category: "WidgetSync")

    private var lastSyncAt: Date?
    private let pendingSyncTask = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    // MARK: - Init

    init(throttleInterval: TimeInterval = 0.5, buildWidgetData: @escaping @MainActor () -> WidgetData) {
        self.buildWidgetData = buildWidgetData
        self.throttleInterval = throttleInterval
    }

    deinit {
        pendingSyncTask.withLock { task in
            task?.cancel()
            task = nil
        }
    }

    // MARK: - Public

    /// Request a widget data write. If a write happened within the throttle
    /// window, the write is deferred and coalesced with any other requests
    /// that land before the window expires.
    func sync() {
        pendingSyncTask.withLock { $0?.cancel(); $0 = nil }

        let now = Date.now
        if let last = lastSyncAt {
            let elapsed = now.timeIntervalSince(last)
            if elapsed < throttleInterval {
                scheduleDeferredWrite(after: throttleInterval - elapsed)
                return
            }
        }
        writeNow()
    }

    /// Write immediately, bypassing the throttle. Used on sign-out so the
    /// widget reflects the empty state right away.
    func writeNow() {
        pendingSyncTask.withLock { $0?.cancel(); $0 = nil }
        let data = buildWidgetData()
        data.save()
        lastSyncAt = .now
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Private

    private func scheduleDeferredWrite(after delay: TimeInterval) {
        let task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.writeNow()
        }
        pendingSyncTask.withLock { $0 = task }
    }
}
