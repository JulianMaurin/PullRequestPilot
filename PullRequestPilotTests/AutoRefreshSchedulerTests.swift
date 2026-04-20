import Testing
import Foundation
import os
@testable import PullRequestPilot

/// Serialized because the scheduler observes
/// `Constants.Notifications.prRefreshIntervalChanged` on the global
/// NotificationCenter — running in parallel would let tests race on the
/// same notification name.
@Suite("AutoRefreshScheduler", .serialized)
struct AutoRefreshSchedulerTests {

    // MARK: - Helpers

    /// Thread-safe counter + optional hook so tests can observe each tick.
    final class TickRecorder: Sendable {
        private let storage = OSAllocatedUnfairLock<(count: Int, onTick: (@Sendable () -> Void)?)>(initialState: (0, nil))

        var count: Int { storage.withLock { $0.count } }

        func setHook(_ hook: @escaping @Sendable () -> Void) {
            storage.withLock { $0.onTick = hook }
        }

        /// Invoked from inside the tick closure.
        func record() {
            let hook = storage.withLock { state -> (@Sendable () -> Void)? in
                state.count += 1
                return state.onTick
            }
            hook?()
        }
    }

    /// Builds a scheduler with an isolated UserDefaults and a short refresh
    /// interval so the loop ticks quickly.
    @MainActor
    private static func makeScheduler(
        suiteName: String,
        intervalSeconds: Double = 0.05
    ) -> (AutoRefreshScheduler, UserDefaults, TickRecorder) {
        let defaults = UserDefaults(suiteName: "AutoRefreshSchedulerTests.\(suiteName)")!
        defaults.removePersistentDomain(forName: "AutoRefreshSchedulerTests.\(suiteName)")
        defaults.set(intervalSeconds, forKey: Constants.UserDefaultsKeys.prRefreshInterval)
        let scheduler = AutoRefreshScheduler(defaults: defaults)
        let recorder = TickRecorder()
        return (scheduler, defaults, recorder)
    }

    @MainActor
    private static func waitUntil(
        deadlineSeconds: Double = 2.0,
        _ predicate: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(deadlineSeconds))
        while !predicate() {
            if ContinuousClock.now >= deadline { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Standard tick result — "have views, no error, no rate limit" — so the
    /// scheduler sleeps the configured interval between ticks.
    private static func haveViewsResult() -> AutoRefreshTickResult {
        AutoRefreshTickResult(hasData: true, hasError: false, maxRateLimitWait: nil, hasViews: true)
    }

    private static func emptyViewsResult() -> AutoRefreshTickResult {
        AutoRefreshTickResult(hasData: false, hasError: false, maxRateLimitWait: nil, hasViews: false)
    }

    // MARK: - tick fires

    @MainActor
    @Test("start() invokes the tick at least once")
    func tickFiresAfterStart() async throws {
        let (scheduler, _, recorder) = Self.makeScheduler(suiteName: "TickFires")
        scheduler.start { @MainActor in
            recorder.record()
            return Self.haveViewsResult()
        }
        try await Self.waitUntil { recorder.count >= 1 }
        scheduler.stop()
        #expect(recorder.count >= 1)
    }

    // MARK: - idempotence

    @MainActor
    @Test("a second start() while already running does not spawn a parallel loop")
    func idempotentStart() async throws {
        let (scheduler, _, recorder) = Self.makeScheduler(suiteName: "Idempotent", intervalSeconds: 0.1)
        let tick: AutoRefreshScheduler.Tick = { @MainActor in
            recorder.record()
            return Self.haveViewsResult()
        }
        scheduler.start(tick: tick)
        // Call start() again immediately; the scheduler should ignore the
        // second call because a loop is already running.
        scheduler.start(tick: tick)
        // Wait for at least 3 ticks. With two parallel loops ticking every
        // 100 ms we would see ~6 ticks in 300 ms; with one loop we see ~3.
        // We assert the rate matches a single loop (i.e. not more than ~5
        // ticks in the same window — generous upper bound to dodge flakes).
        try await Self.waitUntil(deadlineSeconds: 0.4) { recorder.count >= 3 }
        scheduler.stop()
        #expect(recorder.count >= 3)
        #expect(recorder.count <= 5, "Rate implies two parallel loops — start() is not idempotent (\(recorder.count) ticks)")
    }

    // MARK: - stop cancels in-flight

    @MainActor
    @Test("stop() cancels subsequent ticks")
    func stopCancels() async throws {
        let (scheduler, _, recorder) = Self.makeScheduler(suiteName: "Stop", intervalSeconds: 0.05)
        scheduler.start { @MainActor in
            recorder.record()
            return Self.haveViewsResult()
        }
        try await Self.waitUntil { recorder.count >= 1 }
        scheduler.stop()
        let countAfterStop = recorder.count
        // Wait past a couple of would-be tick intervals; counter must not grow.
        try await Self.waitUntil(deadlineSeconds: 0.3) { false }
        #expect(recorder.count == countAfterStop)
    }

    // MARK: - empty-views behavior

    @MainActor
    @Test("empty views tick does not tight-loop (uses configured interval)")
    func emptyViewsNotTightLoop() async throws {
        // If the empty-views path fell through to a 5 s tight loop, we would
        // see exactly one tick in this window. The fix makes it honour the
        // configured interval (50 ms here) so we should see several ticks.
        // We assert the interval is respected (rate ≤ 1 tick per 40 ms), but
        // also that ticks DO eventually accumulate (not stuck at 1).
        let (scheduler, _, recorder) = Self.makeScheduler(suiteName: "EmptyViews", intervalSeconds: 0.05)
        scheduler.start { @MainActor in
            recorder.record()
            return Self.emptyViewsResult()
        }
        try await Self.waitUntil(deadlineSeconds: 0.4) { recorder.count >= 3 }
        scheduler.stop()
        #expect(recorder.count >= 3, "empty-views path should tick at the configured interval, not sleep indefinitely")
        #expect(recorder.count <= 12, "empty-views path is ticking faster than the configured interval")
    }

    // MARK: - interval-change notification restarts

    @MainActor
    @Test("refresh interval notification restarts the loop")
    func intervalChangeRestarts() async throws {
        let (scheduler, _, recorder) = Self.makeScheduler(suiteName: "IntervalRestart", intervalSeconds: 1.0)
        scheduler.start { @MainActor in
            recorder.record()
            return Self.haveViewsResult()
        }
        // Wait for the first tick.
        try await Self.waitUntil { recorder.count >= 1 }
        let countBeforeRestart = recorder.count
        // Post the notification — the observer should cancel the sleeping
        // loop and spawn a fresh one. Because the new loop runs the tick
        // immediately, we'll see a new tick even though the interval was 1 s.
        NotificationCenter.default.post(name: Constants.Notifications.prRefreshIntervalChanged, object: nil)
        try await Self.waitUntil { recorder.count > countBeforeRestart }
        scheduler.stop()
        #expect(recorder.count > countBeforeRestart)
    }

    // MARK: - deinit cancels in-flight

    @MainActor
    @Test("dropping the scheduler cancels any in-flight tick loop")
    func deinitCancels() async throws {
        let defaults = UserDefaults(suiteName: "AutoRefreshSchedulerTests.Deinit")!
        defaults.removePersistentDomain(forName: "AutoRefreshSchedulerTests.Deinit")
        defaults.set(0.05, forKey: Constants.UserDefaultsKeys.prRefreshInterval)
        let recorder = TickRecorder()

        // Construct the scheduler inline without binding it to an extra local
        // variable — `optional = nil` must be the last strong reference.
        var optional: AutoRefreshScheduler? = AutoRefreshScheduler(defaults: defaults)
        optional?.start { @MainActor in
            recorder.record()
            return Self.haveViewsResult()
        }
        try await Self.waitUntil { recorder.count >= 1 }
        optional = nil
        let countAfterDrop = recorder.count
        // Allow one straggler tick that may have already been in flight
        // between the `await tick()` and the `if self == nil { return }`
        // check in the refresh loop. Beyond that, the counter must stop.
        try await Self.waitUntil(deadlineSeconds: 0.3) { false }
        #expect(recorder.count <= countAfterDrop + 1, "counter kept growing after deinit: \(recorder.count) vs \(countAfterDrop)")
    }
}
