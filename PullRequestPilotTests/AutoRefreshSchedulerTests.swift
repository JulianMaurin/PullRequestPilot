import Testing
import Foundation
import os
@testable import PullRequestPilot

@Suite("AutoRefreshScheduler")
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

    /// Builds a scheduler with an isolated UserDefaults, a private
    /// NotificationCenter (so posts from parallel suites on the global center
    /// cannot restart the loop under test), and a short refresh interval so
    /// the loop ticks quickly.
    @MainActor
    private static func makeScheduler(
        suiteName: String,
        intervalSeconds: Double = 0.05
    ) throws -> (AutoRefreshScheduler, UserDefaults, TickRecorder, NotificationCenter) {
        let defaults = try #require(UserDefaults(suiteName: "AutoRefreshSchedulerTests.\(suiteName)"))
        defaults.removePersistentDomain(forName: "AutoRefreshSchedulerTests.\(suiteName)")
        defaults.set(intervalSeconds, forKey: Constants.UserDefaultsKeys.prRefreshInterval)
        let center = NotificationCenter()
        let scheduler = AutoRefreshScheduler(defaults: defaults, notificationCenter: center)
        let recorder = TickRecorder()
        return (scheduler, defaults, recorder, center)
    }

    /// Standard tick result — "have views, no error, no rate limit" — so the
    /// scheduler sleeps the configured interval between ticks.
    private static func haveViewsResult() -> AutoRefreshTickResult {
        AutoRefreshTickResult(hasData: true, hasError: false, maxRateLimitWait: nil, hasViews: true)
    }

    private static func emptyViewsResult() -> AutoRefreshTickResult {
        AutoRefreshTickResult(hasData: false, hasError: false, maxRateLimitWait: nil, hasViews: false)
    }

    /// Views configured, refresh completed cleanly, every result set empty.
    private static func emptyResultsResult() -> AutoRefreshTickResult {
        AutoRefreshTickResult(hasData: false, hasError: false, maxRateLimitWait: nil, hasViews: true)
    }

    // MARK: - tick fires

    @MainActor
    @Test("start() invokes the tick at least once")
    func tickFiresAfterStart() async throws {
        let (scheduler, _, recorder, _) = try Self.makeScheduler(suiteName: "TickFires")
        scheduler.start { @MainActor in
            recorder.record()
            return Self.haveViewsResult()
        }
        try await TestWait.until { recorder.count >= 1 }
        scheduler.stop()
        #expect(recorder.count >= 1)
    }

    // MARK: - idempotence

    @MainActor
    @Test("a second start() while already running does not spawn a parallel loop")
    func idempotentStart() async throws {
        let (scheduler, _, recorder, _) = try Self.makeScheduler(suiteName: "Idempotent", intervalSeconds: 0.1)
        // Each loop ticks as soon as it starts, then parks in the tick until
        // stop() cancels it: every loop records exactly once.
        let tick: AutoRefreshScheduler.Tick = { @MainActor in
            recorder.record()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                // stop() cancelled the loop.
            }
            return Self.haveViewsResult()
        }
        scheduler.start(tick: tick)
        scheduler.start(tick: tick)
        // A second loop's task is queued on the main actor right behind the
        // first, so it has ticked by the time the first tick is observed.
        try await TestWait.until { recorder.count >= 1 }
        scheduler.stop()

        #expect(recorder.count == 1)
    }

    // MARK: - stop cancels in-flight

    @MainActor
    @Test("stop() cancels subsequent ticks")
    func stopCancels() async throws {
        let (scheduler, _, recorder, _) = try Self.makeScheduler(suiteName: "Stop", intervalSeconds: 0.05)
        scheduler.start { @MainActor in
            recorder.record()
            return Self.haveViewsResult()
        }
        try await TestWait.until { recorder.count >= 1 }
        scheduler.stop()
        let countAfterStop = recorder.count
        // Wait past a couple of would-be tick intervals; counter must not grow.
        try await TestWait.until(timeout: .milliseconds(300)) { false }
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
        let (scheduler, _, recorder, _) = try Self.makeScheduler(suiteName: "EmptyViews", intervalSeconds: 0.05)
        scheduler.start { @MainActor in
            recorder.record()
            return Self.emptyViewsResult()
        }
        try await TestWait.until(timeout: .milliseconds(400)) { recorder.count >= 3 }
        scheduler.stop()
        #expect(recorder.count >= 3, "empty-views path should tick at the configured interval, not sleep indefinitely")
        #expect(recorder.count <= 12, "empty-views path is ticking faster than the configured interval")
    }

    // MARK: - empty-results delay policy

    @MainActor
    @Test("steady-state empty results honour the configured interval, not the 30s fast poll")
    func emptyResultsHonourConfiguredInterval() async throws {
        let (_, defaults, _, _) = try Self.makeScheduler(suiteName: "EmptyResults", intervalSeconds: 1800)
        var consecutiveErrors = 0
        var consecutiveEmptyResults = 0
        // First empty tick is the bootstrap grace: fast poll.
        let first = AutoRefreshScheduler.nextDelay(
            result: Self.emptyResultsResult(),
            consecutiveErrors: &consecutiveErrors,
            consecutiveEmptyResults: &consecutiveEmptyResults,
            defaults: defaults
        )
        #expect(first == 30)
        // Every consecutive empty tick sleeps the configured interval.
        for _ in 0..<3 {
            let delay = AutoRefreshScheduler.nextDelay(
                result: Self.emptyResultsResult(),
                consecutiveErrors: &consecutiveErrors,
                consecutiveEmptyResults: &consecutiveEmptyResults,
                defaults: defaults
            )
            #expect(delay == 1800, "steady-state empty results must sleep the configured interval, not fast-poll")
        }
    }

    @MainActor
    @Test("a data tick re-arms the empty-results bootstrap fast poll")
    func emptyResultsFastPollReArmsAfterData() async throws {
        let (_, defaults, _, _) = try Self.makeScheduler(suiteName: "EmptyResultsReArm", intervalSeconds: 1800)
        var consecutiveErrors = 0
        var consecutiveEmptyResults = 0
        _ = AutoRefreshScheduler.nextDelay(
            result: Self.emptyResultsResult(),
            consecutiveErrors: &consecutiveErrors,
            consecutiveEmptyResults: &consecutiveEmptyResults,
            defaults: defaults
        )
        let dataDelay = AutoRefreshScheduler.nextDelay(
            result: Self.haveViewsResult(),
            consecutiveErrors: &consecutiveErrors,
            consecutiveEmptyResults: &consecutiveEmptyResults,
            defaults: defaults
        )
        #expect(dataDelay == 1800)
        let afterData = AutoRefreshScheduler.nextDelay(
            result: Self.emptyResultsResult(),
            consecutiveErrors: &consecutiveErrors,
            consecutiveEmptyResults: &consecutiveEmptyResults,
            defaults: defaults
        )
        #expect(afterData == 30, "data followed by no data may be a transient, so one fast poll is allowed")
    }

    @MainActor
    @Test("empty-results fast poll never sleeps longer than a sub-30s configured interval")
    func emptyResultsFastPollCappedByInterval() async throws {
        let (_, defaults, _, _) = try Self.makeScheduler(suiteName: "EmptyResultsCap", intervalSeconds: 10)
        var consecutiveErrors = 0
        var consecutiveEmptyResults = 0
        let first = AutoRefreshScheduler.nextDelay(
            result: Self.emptyResultsResult(),
            consecutiveErrors: &consecutiveErrors,
            consecutiveEmptyResults: &consecutiveEmptyResults,
            defaults: defaults
        )
        #expect(first == 10)
    }

    // MARK: - sleep, wake and reachability

    /// A scheduler fed by a test-controlled availability stream. The interval
    /// is long, so every tick observed comes from a start or a resume.
    @MainActor
    private static func makeAvailabilityScheduler(
        suiteName: String
    ) throws -> (AutoRefreshScheduler, TickRecorder, AsyncStream<SystemAvailabilityEvent>.Continuation) {
        let defaults = try #require(UserDefaults(suiteName: "AutoRefreshSchedulerTests.\(suiteName)"))
        defaults.removePersistentDomain(forName: "AutoRefreshSchedulerTests.\(suiteName)")
        defaults.set(3600.0, forKey: Constants.UserDefaultsKeys.prRefreshInterval)
        let (events, continuation) = AsyncStream.makeStream(of: SystemAvailabilityEvent.self)
        let scheduler = AutoRefreshScheduler(defaults: defaults, notificationCenter: NotificationCenter(), availabilityEvents: events)
        return (scheduler, TickRecorder(), continuation)
    }

    /// Lets the scheduler's event observer drain what was just yielded.
    @MainActor
    private static func deliverEvents() async {
        for _ in 0..<50 { await Task.yield() }
    }

    @MainActor
    @Test("reconnecting after an outage refreshes immediately")
    func reconnectTicksImmediately() async throws {
        let (scheduler, recorder, events) = try Self.makeAvailabilityScheduler(suiteName: "Reconnect")
        defer { scheduler.stop() }
        scheduler.start { @MainActor in
            recorder.record()
            return Self.haveViewsResult()
        }
        try await TestWait.until { recorder.count >= 1 }

        events.yield(.networkReachabilityChanged(isReachable: false))
        await Self.deliverEvents()
        events.yield(.networkReachabilityChanged(isReachable: true))
        try await TestWait.until { recorder.count >= 2 }

        #expect(recorder.count == 2)
    }

    @MainActor
    @Test("starting while offline waits for the network instead of failing a tick")
    func startWhileOfflineWaits() async throws {
        let (scheduler, recorder, events) = try Self.makeAvailabilityScheduler(suiteName: "StartOffline")
        defer { scheduler.stop() }
        events.yield(.networkReachabilityChanged(isReachable: false))
        await Self.deliverEvents()

        scheduler.start { @MainActor in
            recorder.record()
            return Self.haveViewsResult()
        }
        await Self.deliverEvents()
        #expect(recorder.count == 0)

        events.yield(.networkReachabilityChanged(isReachable: true))
        try await TestWait.until { recorder.count >= 1 }
        #expect(recorder.count == 1)
    }

    @MainActor
    @Test("waking from sleep refreshes immediately; staying awake does not re-tick")
    func wakeTicksImmediately() async throws {
        let (scheduler, recorder, events) = try Self.makeAvailabilityScheduler(suiteName: "Wake")
        defer { scheduler.stop() }
        scheduler.start { @MainActor in
            recorder.record()
            return Self.haveViewsResult()
        }
        try await TestWait.until { recorder.count >= 1 }

        // Reachability reported while awake and online is not a transition.
        events.yield(.networkReachabilityChanged(isReachable: true))
        events.yield(.sleepStarted)
        await Self.deliverEvents()
        #expect(recorder.count == 1)

        events.yield(.sleepEnded)
        try await TestWait.until { recorder.count >= 2 }
        #expect(recorder.count == 2)
    }

    @MainActor
    @Test("waking while still offline waits for the network")
    func wakeWhileOfflineWaits() async throws {
        let (scheduler, recorder, events) = try Self.makeAvailabilityScheduler(suiteName: "WakeOffline")
        defer { scheduler.stop() }
        scheduler.start { @MainActor in
            recorder.record()
            return Self.haveViewsResult()
        }
        try await TestWait.until { recorder.count >= 1 }

        events.yield(.sleepStarted)
        events.yield(.networkReachabilityChanged(isReachable: false))
        events.yield(.sleepEnded)
        await Self.deliverEvents()
        #expect(recorder.count == 1)

        events.yield(.networkReachabilityChanged(isReachable: true))
        try await TestWait.until { recorder.count >= 2 }
        #expect(recorder.count == 2)
    }

    // MARK: - rate-limit and error delay policy

    @MainActor
    @Test("a rate-limit wait applies even while views still show their rows")
    func rateLimitWaitHonouredWithData() async throws {
        let (_, defaults, _, _) = try Self.makeScheduler(suiteName: "RateLimitWithData", intervalSeconds: 60)
        var consecutiveErrors = 0
        var consecutiveEmptyResults = 0
        let delay = AutoRefreshScheduler.nextDelay(
            result: AutoRefreshTickResult(hasData: true, hasError: true, maxRateLimitWait: 900, hasViews: true),
            consecutiveErrors: &consecutiveErrors,
            consecutiveEmptyResults: &consecutiveEmptyResults,
            defaults: defaults
        )
        #expect(delay == 900)
    }

    @MainActor
    @Test("a short rate-limit wait never polls faster than the configured interval")
    func rateLimitWaitNeverUndercutsInterval() async throws {
        let (_, defaults, _, _) = try Self.makeScheduler(suiteName: "RateLimitShortWait", intervalSeconds: 300)
        var consecutiveErrors = 0
        var consecutiveEmptyResults = 0
        let delay = AutoRefreshScheduler.nextDelay(
            result: AutoRefreshTickResult(hasData: false, hasError: true, maxRateLimitWait: 20, hasViews: true),
            consecutiveErrors: &consecutiveErrors,
            consecutiveEmptyResults: &consecutiveEmptyResults,
            defaults: defaults
        )
        #expect(delay == 300)
    }

    @MainActor
    @Test("error backoff grows toward a long configured interval instead of capping at a minute")
    func errorBackoffReachesConfiguredInterval() async throws {
        let (_, defaults, _, _) = try Self.makeScheduler(suiteName: "ErrorBackoffLong", intervalSeconds: 1800)
        var consecutiveErrors = 0
        var consecutiveEmptyResults = 0
        let delays = (0..<10).map { _ in
            AutoRefreshScheduler.nextDelay(
                result: AutoRefreshTickResult(hasData: false, hasError: true, maxRateLimitWait: nil, hasViews: true),
                consecutiveErrors: &consecutiveErrors,
                consecutiveEmptyResults: &consecutiveEmptyResults,
                defaults: defaults
            )
        }
        #expect(delays == [10, 20, 40, 80, 160, 320, 640, 1280, 1800, 1800])
    }

    @MainActor
    @Test("error backoff with the default interval still settles at a minute")
    func errorBackoffDefaultInterval() async throws {
        let (_, defaults, _, _) = try Self.makeScheduler(suiteName: "ErrorBackoffDefault", intervalSeconds: 60)
        var consecutiveErrors = 0
        var consecutiveEmptyResults = 0
        let delays = (0..<5).map { _ in
            AutoRefreshScheduler.nextDelay(
                result: AutoRefreshTickResult(hasData: false, hasError: true, maxRateLimitWait: nil, hasViews: true),
                consecutiveErrors: &consecutiveErrors,
                consecutiveEmptyResults: &consecutiveEmptyResults,
                defaults: defaults
            )
        }
        #expect(delays == [10, 20, 40, 60, 60])
    }

    // MARK: - interval-change notification restarts

    @MainActor
    @Test("refresh interval notification restarts the loop")
    func intervalChangeRestarts() async throws {
        let (scheduler, _, recorder, center) = try Self.makeScheduler(suiteName: "IntervalRestart", intervalSeconds: 1.0)
        scheduler.start { @MainActor in
            recorder.record()
            return Self.haveViewsResult()
        }
        // Wait for the first tick.
        try await TestWait.until { recorder.count >= 1 }
        let countBeforeRestart = recorder.count
        // Post the notification — the observer should cancel the sleeping
        // loop and spawn a fresh one. Because the new loop runs the tick
        // immediately, we'll see a new tick even though the interval was 1 s.
        center.post(name: Constants.Notifications.prRefreshIntervalChanged, object: nil)
        try await TestWait.until { recorder.count > countBeforeRestart }
        scheduler.stop()
        #expect(recorder.count > countBeforeRestart)
    }

    @MainActor
    @Test("interval notification only restarts the scheduler observing that center")
    func intervalChangeScopedToInjectedCenter() async throws {
        let (schedulerA, _, recorderA, centerA) = try Self.makeScheduler(suiteName: "CenterA", intervalSeconds: 5.0)
        let (schedulerB, _, recorderB, _) = try Self.makeScheduler(suiteName: "CenterB", intervalSeconds: 5.0)
        schedulerA.start { @MainActor in
            recorderA.record()
            return Self.haveViewsResult()
        }
        schedulerB.start { @MainActor in
            recorderB.record()
            return Self.haveViewsResult()
        }
        try await TestWait.until { recorderA.count >= 1 && recorderB.count >= 1 }
        let countABefore = recorderA.count
        let countBBefore = recorderB.count
        centerA.post(name: Constants.Notifications.prRefreshIntervalChanged, object: nil)
        try await TestWait.until { recorderA.count > countABefore }
        schedulerA.stop()
        schedulerB.stop()
        #expect(recorderA.count > countABefore)
        #expect(recorderB.count == countBBefore, "a post on another scheduler's center must not restart this loop")
    }

    // MARK: - deinit cancels in-flight

    @MainActor
    @Test("dropping the scheduler cancels any in-flight tick loop")
    func deinitCancels() async throws {
        let defaults = try #require(UserDefaults(suiteName: "AutoRefreshSchedulerTests.Deinit"))
        defaults.removePersistentDomain(forName: "AutoRefreshSchedulerTests.Deinit")
        defaults.set(0.05, forKey: Constants.UserDefaultsKeys.prRefreshInterval)
        let recorder = TickRecorder()

        // Construct the scheduler inline without binding it to an extra local
        // variable — `optional = nil` must be the last strong reference.
        var optional: AutoRefreshScheduler? = AutoRefreshScheduler(
            defaults: defaults,
            notificationCenter: NotificationCenter()
        )
        optional?.start { @MainActor in
            recorder.record()
            return Self.haveViewsResult()
        }
        try await TestWait.until { recorder.count >= 1 }
        optional = nil
        let countAfterDrop = recorder.count
        // Allow one straggler tick that may have already been in flight
        // between the `await tick()` and the `if self == nil { return }`
        // check in the refresh loop. Beyond that, the counter must stop.
        try await TestWait.until(timeout: .milliseconds(300)) { false }
        #expect(recorder.count <= countAfterDrop + 1, "counter kept growing after deinit: \(recorder.count) vs \(countAfterDrop)")
    }
}
