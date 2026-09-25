import Foundation

/// Minimal controllable Clock for deterministic tests.
///
/// Waiters suspended inside `try sleep(until:)` resume only when `advance(by:)`
/// pushes `now` past their deadline. No real wall-clock sleep, no flakiness
/// under parallel test runners.
final class TestClock: Clock, @unchecked Sendable {

    struct Instant: InstantProtocol, Sendable {
        let offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    typealias Duration = Swift.Duration

    private let lock = NSLock()
    private var _now: Instant = Instant(offset: .zero)
    private var waiters: [Waiter] = []

    private struct Waiter {
        let id: UUID
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    var now: Instant { lock.withLock { _now } }
    var minimumResolution: Duration { .zero }

    /// Sleepers currently parked. Tests wait for a sleeper before advancing,
    /// so its deadline is computed from the time they expect.
    var sleeperCount: Int { lock.withLock { waiters.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                lock.lock()
                // A cancellation that landed before this point ran its
                // handler with no waiter to remove; honour it here.
                if Task.isCancelled {
                    lock.unlock()
                    cont.resume(throwing: CancellationError())
                } else if deadline <= _now {
                    lock.unlock()
                    cont.resume()
                } else {
                    waiters.append(Waiter(id: id, deadline: deadline, continuation: cont))
                    lock.unlock()
                }
            }
        } onCancel: { [self] in
            lock.lock()
            if let idx = waiters.firstIndex(where: { $0.id == id }) {
                let w = waiters.remove(at: idx)
                lock.unlock()
                w.continuation.resume(throwing: CancellationError())
            } else {
                lock.unlock()
            }
        }
    }

    /// Advance the clock by `duration` and resume every waiter whose deadline
    /// is now in the past.
    func advance(by duration: Duration) {
        lock.lock()
        _now = _now.advanced(by: duration)
        let fired = waiters.filter { $0.deadline <= _now }
        waiters.removeAll { $0.deadline <= _now }
        lock.unlock()
        fired.forEach { $0.continuation.resume() }
    }
}
