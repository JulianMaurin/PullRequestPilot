import Foundation
import os
import Testing

@testable import PullRequestPilot

@Suite("GitHubClient coalescing", .serialized)
struct GitHubClientCoalescingTests {

    private func makeClient(token: String = "valid") -> (client: GitHubClient, http: MockHTTPSession) {
        let http = MockHTTPSession()
        return (GitHubClient(tokenProvider: { token }, session: http.urlSession), http)
    }

    /// Two concurrent fetches for the same query + token should hit the
    /// network once. This is the core promise of the coalescer.
    @Test("identical concurrent queries hit the network once")
    func concurrentIdenticalQueriesShareOneRequest() async throws {
        let (client, http) = makeClient()
        let callCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let body = #"{"data":{"search":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}"#
        http.handler = { request in
            callCount.withLock { $0 += 1 }
            // Hold the response a beat so the two callers have time to coalesce.
            Thread.sleep(forTimeInterval: 0.02)
            return try TestHTTP.response(for: request, body: Data(body.utf8))
        }

        async let first = client.fetchPullRequests(query: "is:pr review-requested:@me", cursor: nil)
        async let second = client.fetchPullRequests(query: "is:pr review-requested:@me", cursor: nil)
        _ = try await (first, second)

        #expect(callCount.withLock { $0 } == 1)
    }

    /// Distinct queries must not be coalesced — both must reach the network.
    @Test("distinct queries each hit the network")
    func distinctQueriesRunSeparately() async throws {
        let (client, http) = makeClient()
        let callCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let body = #"{"data":{"search":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}"#
        http.handler = { request in
            callCount.withLock { $0 += 1 }
            Thread.sleep(forTimeInterval: 0.02)
            return try TestHTTP.response(for: request, body: Data(body.utf8))
        }

        async let first = client.fetchPullRequests(query: "is:pr author:alice", cursor: nil)
        async let second = client.fetchPullRequests(query: "is:pr author:bob", cursor: nil)
        _ = try await (first, second)

        #expect(callCount.withLock { $0 } == 2)
    }

    /// Approximates the plan's done-criteria regression test: many concurrent
    /// view refreshes with high overlap should collapse to the distinct-query
    /// count on the wire.
    @Test("10 concurrent refreshes with 80% overlap drop to distinct count")
    func heavyOverlapDropsToDistinct() async throws {
        let (client, http) = makeClient()
        let callCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let body = #"{"data":{"search":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}"#
        http.handler = { request in
            callCount.withLock { $0 += 1 }
            Thread.sleep(forTimeInterval: 0.03)
            return try TestHTTP.response(for: request, body: Data(body.utf8))
        }

        // 10 fetches across 2 distinct queries (8 of "shared", 2 of "unique").
        let queries = Array(repeating: "is:pr review-requested:@me", count: 8)
                    + ["is:pr author:alice", "is:pr author:bob"]

        try await withThrowingTaskGroup(of: Void.self) { group in
            for q in queries {
                group.addTask { _ = try await client.fetchPullRequests(query: q, cursor: nil) }
            }
            try await group.waitForAll()
        }

        #expect(callCount.withLock { $0 } == 3)
    }
}
