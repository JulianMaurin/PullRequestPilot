import Foundation
import Testing

@testable import PullRequestPilot

@Suite("RequestCoalescer")
struct RequestCoalescerTests {

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    /// Holds operations in flight until the test opens it, so callers can
    /// join while an operation is provably still running.
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    @Test("a caller that arrives while an operation runs joins it instead of running its own")
    func twoConcurrentCallsCoalesce() async throws {
        let coalescer = RequestCoalescer<String, Int>()
        let started = Counter()
        let gate = Gate()

        async let first: Int = coalescer.run(key: "k") {
            await started.increment()
            await gate.wait()
            return 42
        }
        try await TestWait.until { await started.value == 1 }
        async let second: Int = coalescer.run(key: "k") {
            await started.increment()
            return -1
        }
        try await TestWait.until { await coalescer.joinedCallerCount == 1 }
        await gate.open()

        let results = try await (first, second)
        #expect(results == (42, 42))
        #expect(await started.value == 1)
    }

    @Test("distinct keys run at the same time")
    func distinctKeysRunInParallel() async throws {
        let coalescer = RequestCoalescer<String, Int>()
        let started = Counter()
        let gate = Gate()

        async let first: Int = coalescer.run(key: "a") {
            await started.increment()
            await gate.wait()
            return 1
        }
        async let second: Int = coalescer.run(key: "b") {
            await started.increment()
            await gate.wait()
            return 2
        }
        // Both operations are in flight at once; a serialized coalescer would
        // leave the second waiting behind the gated first.
        try await TestWait.until { await started.value == 2 }
        let startedTogether = await started.value
        await gate.open()

        let results = try await (first, second)
        #expect(startedTogether == 2)
        #expect(results == (1, 2))
    }

    @Test("an error reaches every caller that joined the operation")
    func errorPropagatesToAllCallers() async throws {
        let coalescer = RequestCoalescer<String, Int>()
        let started = Counter()
        let gate = Gate()
        struct Boom: Error {}

        async let first: Int = coalescer.run(key: "k") {
            await started.increment()
            await gate.wait()
            throw Boom()
        }
        try await TestWait.until { await started.value == 1 }
        async let second: Int = coalescer.run(key: "k") {
            await started.increment()
            return -1
        }
        try await TestWait.until { await coalescer.joinedCallerCount == 1 }
        await gate.open()

        var callersThatSawBoom = 0
        do { _ = try await first } catch is Boom { callersThatSawBoom += 1 }
        do { _ = try await second } catch is Boom { callersThatSawBoom += 1 }
        #expect(callersThatSawBoom == 2)
        #expect(await started.value == 1, "the joined caller must not run its own operation")
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
        let started = Counter()
        let gate = Gate()

        let cancellableTask = Task {
            try await coalescer.run(key: "k") {
                await started.increment()
                await gate.wait()
                return 7
            }
        }
        try await TestWait.until { await started.value == 1 }
        cancellableTask.cancel()

        // The shared operation keeps running for callers that join it.
        async let joined: Int = coalescer.run(key: "k") {
            Issue.record("operation re-invoked after cancellation of first caller")
            return -1
        }
        try await TestWait.until { await coalescer.joinedCallerCount >= 1 }
        await gate.open()

        #expect(try await joined == 7)
    }
}
