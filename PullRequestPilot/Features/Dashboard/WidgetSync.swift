import Foundation
import os
import WidgetKit

/// Where `WidgetSync` writes the widgets' data and how it asks WidgetKit to
/// reload. `AppState` passes the app-group file; tests pass a temporary one.
struct WidgetDestination: Sendable {
    /// nil when the app-group container is unavailable.
    let fileURL: URL?
    let reloadTimelines: @Sendable () -> Void

    static var appGroup: WidgetDestination {
        WidgetDestination(fileURL: WidgetData.appGroupFileURL) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

@MainActor
final class WidgetSync {

    // MARK: - Properties

    private let buildWidgetData: @MainActor () -> WidgetData
    private let throttleInterval: TimeInterval
    private let destination: WidgetDestination
    private let logger = Logger(category: "WidgetSync")

    private var lastSyncAt: Date?
    /// Content of the last write that triggered a timeline reload.
    private var lastReloadedViews: [WidgetViewData]?
    private let pendingSyncTask = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    // MARK: - Init

    init(
        throttleInterval: TimeInterval = 0.5,
        destination: WidgetDestination,
        buildWidgetData: @escaping @MainActor () -> WidgetData
    ) {
        self.buildWidgetData = buildWidgetData
        self.throttleInterval = throttleInterval
        self.destination = destination
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
    ///
    /// Timelines reload only when the views changed: WidgetKit rations reloads
    /// requested while the app isn't frontmost (typically 40–70 a day), and a
    /// reload per refresh tick spends that in the first hour. The file is
    /// still rewritten, so the widget's own timeline refresh reads it.
    func writeNow() {
        pendingSyncTask.withLock { $0?.cancel(); $0 = nil }
        let data = buildWidgetData()
        guard let fileURL = destination.fileURL else {
            logger.error("App-group container unavailable; widgets can't be updated")
            return
        }
        data.save(to: fileURL)
        lastSyncAt = .now
        guard data.views != lastReloadedViews else { return }
        lastReloadedViews = data.views
        destination.reloadTimelines()
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
