import AppKit
import Foundation
import Testing

@testable import PullRequestPilot

// MARK: - Avatar Cache Tests

@Suite("AvatarCache")
@MainActor
struct AvatarCacheTests {

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeCache(session: URLSession) -> AvatarCache {
        let cache = AvatarCache(session: session)
        return cache
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
        let session = makeSession()
        let cache = makeCache(session: session)
        let url = URL(string: "https://avatars.example.com/user1.png")!
        let imageData = sampleImageData()

        var fetchCount = 0
        MockURLProtocol.requestHandler = { _ in
            fetchCount += 1
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, imageData)
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
        let session = makeSession()
        let cache = makeCache(session: session)
        let url1 = URL(string: "https://avatars.example.com/user1.png")!
        let url2 = URL(string: "https://avatars.example.com/user2.png")!
        let imageData = sampleImageData()

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, imageData)
        }

        let img1 = await cache.image(for: url1)
        let img2 = await cache.image(for: url2)
        #expect(img1 != nil)
        #expect(img2 != nil)
    }

    // MARK: - Error Paths

    @Test func returnsNilOnNetworkError() async {
        let session = makeSession()
        let cache = makeCache(session: session)
        let url = URL(string: "https://avatars.example.com/fail.png")!

        MockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let result = await cache.image(for: url)
        #expect(result == nil)
    }

    @Test func returnsNilForInvalidImageData() async {
        let session = makeSession()
        let cache = makeCache(session: session)
        let url = URL(string: "https://avatars.example.com/bad.png")!

        MockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("not an image".utf8))
        }

        let result = await cache.image(for: url)
        #expect(result == nil)
    }

    @Test func returnsNilOnCancellation() async {
        let session = makeSession()
        let cache = makeCache(session: session)
        let url = URL(string: "https://avatars.example.com/cancel.png")!

        MockURLProtocol.requestHandler = { _ in
            throw CancellationError()
        }

        let result = await cache.image(for: url)
        #expect(result == nil)
    }
}
