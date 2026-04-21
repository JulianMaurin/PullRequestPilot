import Foundation
import Testing

@testable import PullRequestPilot

@Suite("RequestCoalescer")
struct RequestCoalescerTests {

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    @Test("two concurrent calls with the same key coalesce to a single execution")
    func twoConcurrentCallsCoalesce() async throws {
        let coalescer = RequestCoalescer<String, Int>()
        let counter = Counter()

        async let a: Int = coalescer.run(key: "k") {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(20))
            return 42
        }
        async let b: Int = coalescer.run(key: "k") {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(20))
            return 42
        }

        let results = try await (a, b)
        #expect(results.0 == 42)
        #expect(results.1 == 42)
        let executions = await counter.value
        #expect(executions == 1)
    }

    @Test("distinct keys run in parallel")
    func distinctKeysRunInParallel() async throws {
        let coalescer = RequestCoalescer<String, Int>()
        let counter = Counter()

        async let a: Int = coalescer.run(key: "a") {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(10))
            return 1
        }
        async let b: Int = coalescer.run(key: "b") {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(10))
            return 2
        }

        let results = try await (a, b)
        #expect(results.0 == 1)
        #expect(results.1 == 2)
        let executions = await counter.value
        #expect(executions == 2)
    }

    @Test("error from operation propagates to all coalesced callers")
    func errorPropagatesToAllCallers() async {
        let coalescer = RequestCoalescer<String, Int>()

        struct Boom: Error, Equatable {}

        async let a: Int = coalescer.run(key: "k") {
            try await Task.sleep(for: .milliseconds(10))
            throw Boom()
        }
        async let b: Int = coalescer.run(key: "k") {
            try await Task.sleep(for: .milliseconds(10))
            throw Boom()
        }

        var firstErrored = false
        var secondErrored = false
        do {
            _ = try await a
        } catch is Boom {
            firstErrored = true
        } catch {
            Issue.record("unexpected error from first caller: \(error)")
        }
        do {
            _ = try await b
        } catch is Boom {
            secondErrored = true
        } catch {
            Issue.record("unexpected error from second caller: \(error)")
        }
        #expect(firstErrored)
        #expect(secondErrored)
    }

    @Test("sequential calls run separately — completed tasks don't linger")
    func sequentialCallsRunSeparately() async throws {
        let coalescer = RequestCoalescer<String, Int>()
        let counter = Counter()

        let first = try await coalescer.run(key: "k") {
            await counter.increment()
            return 1
        }
        let second = try await coalescer.run(key: "k") {
            await counter.increment()
            return 2
        }

        #expect(first == 1)
        #expect(second == 2)
        let executions = await counter.value
        #expect(executions == 2)
    }

    @Test("canceling one caller does not affect the other")
    func oneCallerCancelDoesNotAffectOther() async throws {
        let coalescer = RequestCoalescer<String, Int>()

        // Deterministic start-signal: the inner closure yields on the stream
        // as soon as it enters, so the outer test can wait on that instead of
        // a wall-clock sleep. Parallel test runners don't affect correctness.
        let (startedStream, startedContinuation) = AsyncStream.makeStream(of: Void.self)

        let cancellableTask = Task {
            try await coalescer.run(key: "k") {
                startedContinuation.yield()
                try await Task.sleep(for: .milliseconds(50))
                return 7
            }
        }

        var iter = startedStream.makeAsyncIterator()
        _ = await iter.next()
        cancellableTask.cancel()

        // A second caller joining while the task is in flight should still
        // receive the underlying result (coalescer intentionally does not
        // propagate cancellation to the shared task).
        let joined = try await coalescer.run(key: "k") {
            Issue.record("operation re-invoked after cancellation of first caller")
            return -1
        }
        #expect(joined == 7)
    }
}
