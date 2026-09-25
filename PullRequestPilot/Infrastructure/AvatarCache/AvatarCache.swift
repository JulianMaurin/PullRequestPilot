import AppKit
import ImageIO
import os

/// In-memory cache of avatar images, bounded by decoded size and evicted
/// under memory pressure (NSCache). Concurrent requests for one URL share a
/// single fetch through `RequestCoalescer`.
///
/// Avatars are drawn at 32 pt or less, so each is fetched and decoded at
/// `pixelSize`, off the main thread.
@MainActor
final class AvatarCache {
    static let shared = AvatarCache()

    /// Covers the largest avatar (32 pt) on a Retina display.
    nonisolated static let pixelSize = 64

    private let cache = NSCache<NSURL, NSImage>()
    private let coalescer = RequestCoalescer<URL, CGImage>()
    private let session: URLSession
    private let logger = Logger(category: "AvatarCache")

    init(session: URLSession? = nil) {
        // A decoded 64 px avatar is 16 KB: 4 MB holds about 250 of them.
        cache.totalCostLimit = 4 * 1024 * 1024
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.urlCache = URLCache(memoryCapacity: 2 * 1024 * 1024, diskCapacity: 20 * 1024 * 1024)
            self.session = URLSession(configuration: config)
        }
    }

    func image(for url: URL) async -> NSImage? {
        let sizedURL = Self.sizedURL(url)
        if let cached = cache.object(forKey: sizedURL as NSURL) {
            return cached
        }

        let decoded: CGImage
        do {
            let session = self.session
            let logger = self.logger
            decoded = try await coalescer.run(key: sizedURL) {
                let (bytes, response) = try await session.data(from: sizedURL)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    logger.debug("Avatar HTTP \(http.statusCode, privacy: .public) for \(sizedURL, privacy: .private)")
                    throw URLError(.badServerResponse)
                }
                guard let image = Self.downsample(bytes, maxPixelSize: Self.pixelSize) else {
                    throw URLError(.cannotDecodeContentData)
                }
                return image
            }
        } catch is CancellationError {
            return nil
        } catch let urlError as URLError where urlError.code == .cancelled {
            return nil
        } catch {
            logger.debug("Failed to load avatar from \(sizedURL, privacy: .private): \(error, privacy: .public)")
            return nil
        }

        let image = NSImage(cgImage: decoded, size: .zero)
        cache.setObject(image, forKey: sizedURL as NSURL, cost: decoded.bytesPerRow * decoded.height)
        return image
    }

    /// GitHub serves avatars at 460 px unless the `s` parameter asks for a size.
    nonisolated static func sizedURL(_ url: URL) -> URL {
        guard url.host == "avatars.githubusercontent.com",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        var items = (components.queryItems ?? []).filter { $0.name != "s" }
        items.append(URLQueryItem(name: "s", value: String(pixelSize)))
        components.queryItems = items
        return components.url ?? url
    }

    /// Decodes at most `maxPixelSize` on the longest side, fully decoded now
    /// rather than on first draw.
    nonisolated static func downsample(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
