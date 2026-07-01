import AppKit
import Foundation
import os
import Testing

@testable import PullRequestPilot

// MARK: - Avatar Cache Tests

@Suite("AvatarCache", .serialized)
@MainActor
struct AvatarCacheTests {

    private func makeCache(http: MockHTTPSession) -> AvatarCache {
        AvatarCache(session: http.urlSession)
    }

    private func sampleImageData() -> Data {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 1, height: 1))
        image.unlockFocus()
        return image.tiffRepresentation ?? Data()
    }

    // MARK: - Success Paths

    @Test func fetchesAndCachesImage() async {
        let http = MockHTTPSession()
        let cache = makeCache(http: http)
        let url = URL(string: "https://avatars.example.com/user1.png")!
        let imageData = sampleImageData()

        var fetchCount = 0
        http.handler = { _ in
            fetchCount += 1
            return try TestHTTP.response(url: url, body: imageData)
        }

        let first = await cache.image(for: url)
        #expect(first != nil)
        #expect(fetchCount == 1)

        // Second call should use cache, not fetch again
        let second = await cache.image(for: url)
        #expect(second != nil)
        #expect(fetchCount == 1)
    }

    @Test func returnsDifferentImagesForDifferentURLs() async {
        let http = MockHTTPSession()
        let cache = makeCache(http: http)
        let url1 = URL(string: "https://avatars.example.com/user1.png")!
        let url2 = URL(string: "https://avatars.example.com/user2.png")!
        let imageData = sampleImageData()

        http.handler = { request in
            try TestHTTP.response(for: request, body: imageData)
        }

        let img1 = await cache.image(for: url1)
        let img2 = await cache.image(for: url2)
        #expect(img1 != nil)
        #expect(img2 != nil)
    }

    // MARK: - Error Paths

    @Test func returnsNilOnNetworkError() async {
        let http = MockHTTPSession()
        let cache = makeCache(http: http)
        let url = URL(string: "https://avatars.example.com/fail.png")!

        http.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let result = await cache.image(for: url)
        #expect(result == nil)
    }

    @Test func returnsNilForInvalidImageData() async {
        let http = MockHTTPSession()
        let cache = makeCache(http: http)
        let url = URL(string: "https://avatars.example.com/bad.png")!

        http.handler = { _ in
            try TestHTTP.response(url: url, body: Data("not an image".utf8))
        }

        let result = await cache.image(for: url)
        #expect(result == nil)
    }

    @Test func returnsNilOnCancellation() async {
        let http = MockHTTPSession()
        let cache = makeCache(http: http)
        let url = URL(string: "https://avatars.example.com/cancel.png")!

        http.handler = { _ in
            throw CancellationError()
        }

        let result = await cache.image(for: url)
        #expect(result == nil)
    }

    // MARK: - Coalescing

    @Test func concurrentRequestsForSameURLFetchOnce() async {
        let http = MockHTTPSession()
        let cache = makeCache(http: http)
        let url = URL(string: "https://avatars.example.com/shared.png")!
        let imageData = sampleImageData()

        let fetchCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        http.handler = { _ in
            fetchCount.withLock { $0 += 1 }
            Thread.sleep(forTimeInterval: 0.02)
            return try TestHTTP.response(url: url, body: imageData)
        }

        async let first = cache.image(for: url)
        async let second = cache.image(for: url)
        async let third = cache.image(for: url)
        let results = await (first, second, third)

        #expect(results.0 != nil)
        #expect(results.1 != nil)
        #expect(results.2 != nil)
        #expect(fetchCount.withLock { $0 } == 1)
    }
}
