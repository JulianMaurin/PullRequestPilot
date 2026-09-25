import Foundation

/// Deduplicates concurrent async operations that share a key.
///
/// While a task is in flight for a given key, any additional caller with the
/// same key awaits the same task instead of starting its own. Distinct keys
/// run in parallel.
///
/// Cancellation semantics: the underlying task is intentionally **not**
/// cancellable from caller contexts. A caller that cancels its awaiting
/// context simply abandons its wait — other callers (and future callers that
/// join before completion) still see the result. This keeps the coalescer
/// predictable when callers come and go, matches the GitHub/avatar use cases
/// (reads are cheap to complete once started), and avoids the classic
/// "first caller cancels, later callers get spuriously cancelled" footgun.
actor RequestCoalescer<Key: Hashable & Sendable, Value: Sendable> {
    private var inFlight: [Key: Task<Value, Error>] = [:]
    /// Callers currently waiting on an operation another caller started.
    private(set) var joinedCallerCount = 0

    func run(key: Key, operation: @Sendable @escaping () async throws -> Value) async throws -> Value {
        if let existing = inFlight[key] {
            joinedCallerCount += 1
            defer { joinedCallerCount -= 1 }
            return try await existing.value
        }
        let task = Task<Value, Error> { try await operation() }
        inFlight[key] = task
        do {
            let value = try await task.value
            inFlight.removeValue(forKey: key)
            return value
        } catch {
            inFlight.removeValue(forKey: key)
            throw error
        }
    }
}
