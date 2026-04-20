import Testing
import Foundation
import os
@testable import PullRequestPilot

@Suite("WidgetSync")
struct WidgetSyncTests {

    // MARK: - Helpers

    /// Counts how many times the WidgetSync builder is invoked. Each
    /// invocation corresponds to one attempted write. Lock-backed so the
    /// counter is safe across MainActor hops inside the throttle task.
    final class BuildCounter: Sendable {
        private let storage = OSAllocatedUnfairLock(initialState: 0)
        var count: Int { storage.withLock { $0 } }
        func increment() { storage.withLock { $0 += 1 } }
    }

    private static let emptyData = WidgetData(views: [], lastUpdated: Date(timeIntervalSince1970: 0))

    @MainActor
    private static func makeSync(throttleInterval: TimeInterval, counter: BuildCounter) -> WidgetSync {
        WidgetSync(throttleInterval: throttleInterval) {
            counter.increment()
            return emptyData
        }
    }

    /// Polls until `predicate()` becomes true or the deadline expires.
    /// Avoids Task.sleep-as-sync: yields between checks and sleeps briefly
    /// so the MainActor can run the throttled write task.
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

    // MARK: - First sync: immediate write

    @MainActor
    @Test("first sync() writes immediately")
    func firstSyncWritesImmediately() {
        let counter = BuildCounter()
        let sync = Self.makeSync(throttleInterval: 0.05, counter: counter)
        sync.sync()
        #expect(counter.count == 1)
    }

    // MARK: - Throttle coalescing

    @MainActor
    @Test("rapid sync() calls within the throttle window coalesce to one deferred write")
    func rapidSyncsCoalesce() async throws {
        let counter = BuildCounter()
        let sync = Self.makeSync(throttleInterval: 0.05, counter: counter)
        sync.sync()
        // First call is immediate — counter == 1.
        #expect(counter.count == 1)
        // Follow up with four calls inside the throttle window. Each cancels
        // the previous deferred task; only the last's timer actually fires.
        sync.sync()
        sync.sync()
        sync.sync()
        sync.sync()
        // Immediately after those, nothing new has written yet.
        #expect(counter.count == 1)
        // Wait for the deferred write to land.
        try await Self.waitUntil { counter.count >= 2 }
        #expect(counter.count == 2)
    }

    // MARK: - writeNow

    @MainActor
    @Test("writeNow() bypasses the throttle")
    func writeNowBypassesThrottle() {
        let counter = BuildCounter()
        let sync = Self.makeSync(throttleInterval: 5.0, counter: counter)
        sync.sync()
        #expect(counter.count == 1)
        // Well within the 5s throttle window — sync() would normally defer.
        // writeNow() must write immediately anyway.
        sync.writeNow()
        #expect(counter.count == 2)
    }

    @MainActor
    @Test("writeNow() cancels any pending deferred write")
    func writeNowCancelsDeferred() async throws {
        let counter = BuildCounter()
        let sync = Self.makeSync(throttleInterval: 0.2, counter: counter)
        sync.sync() // immediate (count = 1)
        sync.sync() // schedules deferred write
        // Before the deferred fires, call writeNow.
        sync.writeNow() // (count = 2)
        // Give the scheduled timer the chance to fire; it must have been
        // cancelled, so the count should stay at 2.
        try await Self.waitUntil(deadlineSeconds: 0.5) { false }
        #expect(counter.count == 2)
    }

    // MARK: - empty data

    @MainActor
    @Test("an empty builder result still writes through")
    func emptyDataWrites() {
        let counter = BuildCounter()
        let sync = Self.makeSync(throttleInterval: 1.0, counter: counter)
        sync.writeNow()
        #expect(counter.count == 1)
    }

    // MARK: - deinit

    @MainActor
    @Test("deinit cancels the pending deferred write")
    func deinitCancelsPending() async throws {
        let counter = BuildCounter()
        var syncOptional: WidgetSync? = Self.makeSync(throttleInterval: 0.2, counter: counter)
        syncOptional?.sync() // immediate (count = 1)
        syncOptional?.sync() // schedules deferred
        #expect(counter.count == 1)
        // Drop the strong reference. The scheduled task captures `weak self`
        // so when the instance is released the `guard let self` in the sleep
        // handler returns — builder must not be called again.
        syncOptional = nil
        // Wait past the throttle window; no further writes should land.
        try await Self.waitUntil(deadlineSeconds: 0.5) { false }
        #expect(counter.count == 1)
    }
}
