import Foundation
import os

/// Summary that the scheduler uses to pick the next sleep duration.
struct AutoRefreshTickResult: Sendable {
    let hasData: Bool
    let hasError: Bool
    let maxRateLimitWait: TimeInterval?
    let hasViews: Bool
}

@MainActor
final class AutoRefreshScheduler {

    // MARK: - Types

    typealias Tick = @MainActor () async -> AutoRefreshTickResult

    // MARK: - Properties

    private let defaults: UserDefaults

    /// Center the interval-change observer subscribes to. Injected so tests
    /// can isolate schedulers from posts made by parallel suites.
    private let notificationCenter: NotificationCenter

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PullRequestPilot", category: "AutoRefresh")

    /// Tick closure passed to `start()`. Kept on the scheduler so the
    /// interval-observer can restart the loop without the owner having to
    /// re-pass it.
    private var tick: Tick?

    /// Lock-backed storage so `deinit` (outside actor isolation in Swift 6)
    /// can cancel the in-flight tasks.
    private let refreshTask = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    private let intervalObserverTask = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    // MARK: - Init

    init(defaults: UserDefaults, notificationCenter: NotificationCenter = .default) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
    }

    deinit {
        refreshTask.withLock { task in
            task?.cancel()
            task = nil
        }
        intervalObserverTask.withLock { task in
            task?.cancel()
            task = nil
        }
    }

    // MARK: - Public

    /// Idempotent: a second call while already running is a no-op. Stores the
    /// tick closure so the interval observer can restart the loop when the
    /// user changes the configured refresh interval.
    func start(tick: @escaping Tick) {
        self.tick = tick
        let alreadyRunning = refreshTask.withLock { $0 != nil }
        guard !alreadyRunning else { return }
        spawnRefreshLoop(tick: tick)
        startIntervalObserver()
    }

    func stop() {
        refreshTask.withLock { task in
            task?.cancel()
            task = nil
        }
        intervalObserverTask.withLock { task in
            task?.cancel()
            task = nil
        }
    }

    // MARK: - Private

    private func spawnRefreshLoop(tick: @escaping Tick) {
        let defaults = defaults
        let newTask = Task { @MainActor [weak self] in
            var consecutiveErrorFetches = 0
            var consecutiveEmptyFetches = 0
            while !Task.isCancelled {
                let result = await tick()
                let seconds = Self.nextDelay(
                    result: result,
                    consecutiveErrors: &consecutiveErrorFetches,
                    consecutiveEmptyResults: &consecutiveEmptyFetches,
                    defaults: defaults
                )
                do {
                    try await Task.sleep(for: .seconds(seconds))
                } catch {
                    break
                }
                // Touch self so the task is tied to the scheduler's lifetime.
                if self == nil { return }
            }
        }
        refreshTask.withLock { $0 = newTask }
    }

    private func startIntervalObserver() {
        let alreadyObserving = intervalObserverTask.withLock { $0 != nil }
        guard !alreadyObserving else { return }

        let center = notificationCenter
        let observerTask = Task { @MainActor [weak self] in
            for await _ in center.notifications(named: Constants.Notifications.prRefreshIntervalChanged) {
                guard let self else { return }
                if Task.isCancelled { return }
                self.restartLoop()
            }
        }
        intervalObserverTask.withLock { $0 = observerTask }
    }

    private func restartLoop() {
        refreshTask.withLock { task in
            task?.cancel()
            task = nil
        }
        if let tick {
            spawnRefreshLoop(tick: tick)
        }
    }

    /// Internal (not private) so tests can pin the delay policy directly.
    static func nextDelay(
        result: AutoRefreshTickResult,
        consecutiveErrors: inout Int,
        consecutiveEmptyResults: inout Int,
        defaults: UserDefaults
    ) -> Double {
        let interval = configuredInterval(defaults: defaults)
        // Checked first: views keep their rows when a fetch fails, so `hasData`
        // stays true through a rate limit and must not shortcut the wait.
        if let wait = result.maxRateLimitWait, wait > 0 {
            consecutiveEmptyResults = 0
            return min(max(wait, interval), 3600)
        }
        if result.hasData {
            consecutiveErrors = 0
            consecutiveEmptyResults = 0
            return interval
        }
        if result.hasError {
            consecutiveEmptyResults = 0
            consecutiveErrors += 1
            // Fast retries at first, never settling below the user's interval.
            return min(10 * pow(2.0, Double(consecutiveErrors - 1)), max(60, interval))
        }
        if !result.hasViews {
            // No views to refresh — sleep for the user's configured interval
            // (or the default) instead of spinning every 5s. Fixes the
            // "tight loop when idle" bug.
            consecutiveEmptyResults = 0
            return configuredInterval(defaults: defaults)
        }
        // Views exist but every result set is empty. The first such tick may
        // be a not-yet-loaded bootstrap (e.g. the fetch was cancelled before
        // data arrived), so retry fast once; consecutive empty ticks are a
        // legitimately empty queue and honour the configured interval.
        consecutiveEmptyResults += 1
        if consecutiveEmptyResults > 1 {
            return configuredInterval(defaults: defaults)
        }
        return min(30, configuredInterval(defaults: defaults))
    }

    private static func configuredInterval(defaults: UserDefaults) -> Double {
        let interval = defaults.double(forKey: Constants.UserDefaultsKeys.prRefreshInterval)
        return interval > 0 ? interval : Constants.App.defaultPRRefreshInterval
    }
}
