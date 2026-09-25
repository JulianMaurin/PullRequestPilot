import Foundation
import os
import WidgetKit

@MainActor
final class WidgetSync {

    // MARK: - Properties

    private let buildWidgetData: @MainActor () -> WidgetData
    private let throttleInterval: TimeInterval
    /// Write destination override; nil uses the shared app-group container.
    /// Injected by tests so writes never touch real widget data.
    private let storageURL: URL?
    private let reloadTimelines: @Sendable () -> Void
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PullRequestPilot", category: "WidgetSync")

    private var lastSyncAt: Date?
    /// Content of the last write that triggered a timeline reload.
    private var lastReloadedViews: [WidgetViewData]?
    private let pendingSyncTask = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    // MARK: - Init

    init(
        throttleInterval: TimeInterval = 0.5,
        storageURL: URL? = nil,
        reloadTimelines: @escaping @Sendable () -> Void = WidgetSync.reloadRealTimelines,
        buildWidgetData: @escaping @MainActor () -> WidgetData
    ) {
        self.buildWidgetData = buildWidgetData
        self.throttleInterval = throttleInterval
        self.storageURL = storageURL
        self.reloadTimelines = reloadTimelines
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
        if let storageURL {
            data.save(to: storageURL)
        } else {
            data.save()
        }
        lastSyncAt = .now
        guard data.views != lastReloadedViews else { return }
        lastReloadedViews = data.views
        reloadTimelines()
    }

    // MARK: - Private

    /// Default reload action. Skips the real WidgetCenter poke under unit
    /// tests (same guard as NotificationService.deliver) — DashboardViewModel
    /// builds its own WidgetSync, so tests cannot inject a no-op there.
    private nonisolated static func reloadRealTimelines() {
        guard NSClassFromString("XCTestCase") == nil else { return }
        WidgetCenter.shared.reloadAllTimelines()
    }

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
