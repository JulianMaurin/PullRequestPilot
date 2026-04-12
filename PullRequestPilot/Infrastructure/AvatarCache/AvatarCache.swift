import AppKit
import os

/// In-memory LRU cache for avatar images, backed by NSCache which
/// automatically evicts under memory pressure. Capped at 200 entries
/// to prevent unbounded growth. Coalesces concurrent requests for the
/// same URL to avoid duplicate network fetches.
@MainActor
final class AvatarCache {
    static let shared = AvatarCache()

    private let cache = NSCache<NSURL, NSImage>()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]
    private let session: URLSession
    private let logger = Logger(subsystem: "PullRequestPilot", category: "AvatarCache")

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

        if let existing = inFlight[url] {
            return await existing.value
        }

        let task = Task<NSImage?, Never> {
            do {
                let (data, _) = try await session.data(from: url)
                guard let image = NSImage(data: data) else { return nil }
                cache.setObject(image, forKey: url as NSURL)
                return image
            } catch is CancellationError {
                return nil
            } catch let urlError as URLError where urlError.code == .cancelled {
                return nil
            } catch {
                logger.debug("Failed to load avatar from \(url, privacy: .public): \(error, privacy: .public)")
                return nil
            }
        }
        inFlight[url] = task
        let result = await task.value
        inFlight.removeValue(forKey: url)
        return result
    }
}
