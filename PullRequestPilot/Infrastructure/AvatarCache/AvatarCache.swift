import AppKit
import os

/// In-memory LRU cache for avatar images, backed by NSCache which
/// automatically evicts under memory pressure. Capped at 200 entries
/// to prevent unbounded growth.
final class AvatarCache: @unchecked Sendable {
    static let shared = AvatarCache()

    private let cache = NSCache<NSURL, NSImage>()
    private let session: URLSession
    private let logger = Logger(subsystem: "PullRequestPilot", category: "AvatarCache")

    init(session: URLSession? = nil) {
        cache.countLimit = 200
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.urlCache = URLCache(memoryCapacity: 0, diskCapacity: 20 * 1024 * 1024) // 20 MB disk cache
            self.session = URLSession(configuration: config)
        }
    }

    func image(for url: URL) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }

        do {
            let (data, _) = try await session.data(from: url)
            guard let image = NSImage(data: data) else { return nil }
            cache.setObject(image, forKey: url as NSURL)
            return image
        } catch is CancellationError {
            return nil
        } catch {
            logger.debug("Failed to load avatar from \(url, privacy: .public): \(error, privacy: .public)")
            return nil
        }
    }
}
