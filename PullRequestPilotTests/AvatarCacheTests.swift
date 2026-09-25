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
        AvatarCache(session: http.urlSession, cache: NonEvictingCache())
    }

    private func sampleImageData() -> Data {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 1, height: 1))
        image.unlockFocus()
        return image.tiffRepresentation ?? Data()
    }

    // MARK: - Success Paths

    @Test func fetchesAndCachesImage() async throws {
        let http = MockHTTPSession()
        let cache = makeCache(http: http)
        let url = try #require(URL(string: "https://avatars.example.com/user1.png"))
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

    @Test func returnsDifferentImagesForDifferentURLs() async throws {
        let http = MockHTTPSession()
        let cache = makeCache(http: http)
        let url1 = try #require(URL(string: "https://avatars.example.com/user1.png"))
        let url2 = try #require(URL(string: "https://avatars.example.com/user2.png"))
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

    @Test func returnsNilOnNetworkError() async throws {
        let http = MockHTTPSession()
        let cache = makeCache(http: http)
        let url = try #require(URL(string: "https://avatars.example.com/fail.png"))

        http.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let result = await cache.image(for: url)
        #expect(result == nil)
    }

    @Test func returnsNilForInvalidImageData() async throws {
        let http = MockHTTPSession()
        let cache = makeCache(http: http)
        let url = try #require(URL(string: "https://avatars.example.com/bad.png"))

        http.handler = { _ in
            try TestHTTP.response(url: url, body: Data("not an image".utf8))
        }

        let result = await cache.image(for: url)
        #expect(result == nil)
    }

    @Test func returnsNilOnCancellation() async throws {
        let http = MockHTTPSession()
        let cache = makeCache(http: http)
        let url = try #require(URL(string: "https://avatars.example.com/cancel.png"))

        http.handler = { _ in
            throw CancellationError()
        }

        let result = await cache.image(for: url)
        #expect(result == nil)
    }

    // MARK: - Size

    private func imageData(pixels: Int) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test("GitHub avatars are requested at display size; other hosts are left alone")
    func sizedURL() throws {
        let github = try #require(URL(string: "https://avatars.githubusercontent.com/u/42?v=4"))
        let resized = try #require(URL(string: "https://avatars.githubusercontent.com/u/42?v=4&s=460"))
        let other = try #require(URL(string: "https://example.com/u/42?v=4"))

        #expect(AvatarCache.sizedURL(github).absoluteString == "https://avatars.githubusercontent.com/u/42?v=4&s=64")
        #expect(AvatarCache.sizedURL(resized).absoluteString == "https://avatars.githubusercontent.com/u/42?v=4&s=64")
        #expect(AvatarCache.sizedURL(other) == other)
    }

    @Test("a large avatar is decoded at the display size")
    func downsamplesLargeAvatar() throws {
        let image = try #require(AvatarCache.downsample(try imageData(pixels: 460), maxPixelSize: AvatarCache.pixelSize))
        #expect(image.width == AvatarCache.pixelSize)
        #expect(image.height == AvatarCache.pixelSize)
    }

    @Test("the fetch asks GitHub for the display size")
    func fetchRequestsDisplaySize() async throws {
        let http = MockHTTPSession()
        let cache = makeCache(http: http)
        let url = try #require(URL(string: "https://avatars.githubusercontent.com/u/7?v=4"))
        let imageData = try imageData(pixels: 64)
        var requestedURLs: [URL] = []
        http.handler = { request in
            if let url = request.url { requestedURLs.append(url) }
            return try TestHTTP.response(for: request, body: imageData)
        }

        let image = await cache.image(for: url)

        #expect(image != nil)
        #expect(requestedURLs.map(\.absoluteString) == ["https://avatars.githubusercontent.com/u/7?v=4&s=64"])
    }

    // MARK: - Coalescing

    @Test func concurrentRequestsForSameURLFetchOnce() async throws {
        let http = MockHTTPSession()
        let cache = makeCache(http: http)
        let url = try #require(URL(string: "https://avatars.example.com/shared.png"))
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

/// An `NSCache` that never evicts, so a cache hit in these tests doesn't
/// depend on `NSCache`'s eviction policy.
private final class NonEvictingCache: NSCache<NSURL, NSImage> {
    private let storage = OSAllocatedUnfairLock<[NSURL: NSImage]>(initialState: [:])

    override func object(forKey key: NSURL) -> NSImage? {
        storage.withLockUnchecked { $0[key] }
    }

    override func setObject(_ obj: NSImage, forKey key: NSURL, cost: Int) {
        storage.withLockUnchecked { $0[key] = obj }
    }
}
