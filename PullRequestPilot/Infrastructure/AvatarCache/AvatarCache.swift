import AppKit
import os

/// In-memory LRU cache for avatar images, backed by NSCache which
/// automatically evicts under memory pressure. Capped at 200 entries
/// to prevent unbounded growth. Coalesces concurrent requests for the
/// same URL through a shared `RequestCoalescer` so duplicate network
/// fetches fold into a single round-trip.
@MainActor
final class AvatarCache {
    static let shared = AvatarCache()

    private let cache = NSCache<NSURL, NSImage>()
    private let coalescer = RequestCoalescer<URL, Data>()
    private let session: URLSession
    private let logger = Logger(category: "AvatarCache")

    init(session: URLSession? = nil) {
        cache.countLimit = 200
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.urlCache = URLCache(memoryCapacity: 10 * 1024 * 1024, diskCapacity: 20 * 1024 * 1024) // 10 MB memory + 20 MB disk
            self.session = URLSession(configuration: config)
        }
    }

    func image(for url: URL) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }

        let data: Data
        do {
            let session = self.session
            let logger = self.logger
            data = try await coalescer.run(key: url) {
                let (bytes, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    logger.debug("Avatar HTTP \(http.statusCode, privacy: .public) for \(url, privacy: .public)")
                    throw URLError(.badServerResponse)
                }
                return bytes
            }
        } catch is CancellationError {
            return nil
        } catch let urlError as URLError where urlError.code == .cancelled {
            return nil
        } catch {
            logger.debug("Failed to load avatar from \(url, privacy: .public): \(error, privacy: .public)")
            return nil
        }

        guard let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}
