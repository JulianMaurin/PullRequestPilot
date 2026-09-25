import Foundation

/// Waits for state, not for time: returns as soon as the condition holds and
/// gives up at the deadline, leaving the caller's expectation to report it.
enum TestWait {
    @MainActor
    static func until(timeout: Duration = .seconds(2), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            if ContinuousClock.now >= deadline { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// For conditions that read actor state.
    @MainActor
    static func until(timeout: Duration = .seconds(2), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !(await condition()) {
            if ContinuousClock.now >= deadline { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
