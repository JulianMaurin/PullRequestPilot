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

    private let logger = Logger(category: "AutoRefresh")

    /// Tick closure passed to `start()`. Kept on the scheduler so the
    /// interval-observer can restart the loop without the owner having to
    /// re-pass it.
    private var tick: Tick?

    /// Between `start()` and `stop()`, whether or not the loop is suspended.
    private var isStarted = false
    private var isAsleep = false
    private var isOffline = false
    private var isSuspended: Bool { isAsleep || isOffline }

    /// Sleep/wake and reachability; nil in tests that don't exercise them.
    private let availabilityEvents: AsyncStream<SystemAvailabilityEvent>?

    /// Lock-backed storage so `deinit` (outside actor isolation in Swift 6)
    /// can cancel the in-flight tasks.
    private let refreshTask = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    private let intervalObserverTask = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    private let availabilityObserverTask = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    // MARK: - Init

    init(
        defaults: UserDefaults,
        notificationCenter: NotificationCenter = .default,
        availabilityEvents: AsyncStream<SystemAvailabilityEvent>? = nil
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.availabilityEvents = availabilityEvents
        startAvailabilityObserver()
    }

    deinit {
        for storage in [refreshTask, intervalObserverTask, availabilityObserverTask] {
            storage.withLock { task in
                task?.cancel()
                task = nil
            }
        }
    }

    // MARK: - Public

    /// Idempotent: a second call while already running is a no-op. Stores the
    /// tick closure so the interval observer can restart the loop when the
    /// user changes the configured refresh interval. While asleep or offline
    /// the loop waits and starts on the next wake or reconnect.
    func start(tick: @escaping Tick) {
        self.tick = tick
        guard !isStarted else { return }
        isStarted = true
        if !isSuspended {
            spawnRefreshLoop(tick: tick)
        }
        startIntervalObserver()
    }

    func stop() {
        isStarted = false
        cancelRefreshLoop()
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
        cancelRefreshLoop()
        if let tick, isStarted, !isSuspended {
            spawnRefreshLoop(tick: tick)
        }
    }

    private func cancelRefreshLoop() {
        refreshTask.withLock { task in
            task?.cancel()
            task = nil
        }
    }

    private func startAvailabilityObserver() {
        guard let availabilityEvents else { return }
        let observerTask = Task { @MainActor [weak self] in
            for await event in availabilityEvents {
                guard let self else { return }
                self.handle(event)
            }
        }
        availabilityObserverTask.withLock { $0 = observerTask }
    }

    /// Asleep or offline, a tick can only fail (and toast); the loop stops and
    /// restarts with an immediate refresh once both clear.
    private func handle(_ event: SystemAvailabilityEvent) {
        let wasSuspended = isSuspended
        switch event {
        case .sleepStarted: isAsleep = true
        case .sleepEnded: isAsleep = false
        case .networkReachabilityChanged(let isReachable): isOffline = !isReachable
        }
        guard wasSuspended != isSuspended else { return }
        logger.info("Auto-refresh \(self.isSuspended ? "suspended" : "resumed", privacy: .public) (asleep: \(self.isAsleep, privacy: .public), offline: \(self.isOffline, privacy: .public))")
        if isSuspended {
            cancelRefreshLoop()
        } else {
            restartLoop()
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
