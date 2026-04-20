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

    init(defaults: UserDefaults) {
        self.defaults = defaults
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
            while !Task.isCancelled {
                let result = await tick()
                let seconds = Self.nextDelay(
                    result: result,
                    consecutiveErrors: &consecutiveErrorFetches,
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

        let observerTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: Constants.Notifications.prRefreshIntervalChanged) {
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

    private static func nextDelay(result: AutoRefreshTickResult, consecutiveErrors: inout Int, defaults: UserDefaults) -> Double {
        if result.hasData {
            consecutiveErrors = 0
            let interval = defaults.double(forKey: Constants.UserDefaultsKeys.prRefreshInterval)
            return interval > 0 ? interval : Constants.App.defaultPRRefreshInterval
        }
        if result.hasError {
            if let wait = result.maxRateLimitWait, wait > 0 {
                return min(max(wait, 10), 3600)
            }
            consecutiveErrors += 1
            return min(10 * pow(2.0, Double(consecutiveErrors - 1)), 60)
        }
        if !result.hasViews {
            // No views to refresh — sleep for the user's configured interval
            // (or the default) instead of spinning every 5s. Fixes the
            // "tight loop when idle" bug.
            let interval = defaults.double(forKey: Constants.UserDefaultsKeys.prRefreshInterval)
            return interval > 0 ? interval : Constants.App.defaultPRRefreshInterval
        }
        return 30
    }
}
