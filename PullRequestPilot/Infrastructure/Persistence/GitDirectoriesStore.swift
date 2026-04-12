import Foundation
import os

final class GitDirectoriesStore: @unchecked Sendable {
    private static let key = "git_directory_bookmarks"
    private static let legacyKey = "git_directories"
    private let defaults: UserDefaults
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "PullRequestPilot",
        category: "GitDirectoriesStore"
    )

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateLegacyPathsIfNeeded()
    }

    // MARK: - Public

    func load() -> [URL] {
        guard let bookmarksData = defaults.array(forKey: Self.key) as? [Data] else {
            return []
        }
        return bookmarksData.compactMap { resolveBookmark($0) }
    }

    func save(_ directories: [URL]) {
        // Build a map of existing bookmarks keyed by resolved path so we can
        // preserve the original bookmark data (with its security scope) instead
        // of recreating bookmarks, which may fail if security-scoped access expired.
        let existingBookmarks = defaults.array(forKey: Self.key) as? [Data] ?? []
        var bookmarkByPath: [String: Data] = [:]
        for data in existingBookmarks {
            if let url = resolveBookmark(data) {
                bookmarkByPath[url.path] = data
            }
        }

        let result = directories.compactMap { url -> Data? in
            // Prefer the existing bookmark; fall back to creating a new one
            bookmarkByPath[url.path] ?? createBookmark(for: url)
        }
        defaults.set(result, forKey: Self.key)
    }

    func saveFromPanel(_ url: URL) -> URL? {
        guard let bookmarkData = createBookmark(for: url) else { return nil }
        var existing = defaults.array(forKey: Self.key) as? [Data] ?? []
        existing.append(bookmarkData)
        defaults.set(existing, forKey: Self.key)
        return url
    }

    // MARK: - Security-Scoped Access

    func startAccessing(_ urls: [URL]) {
        for url in urls {
            if url.startAccessingSecurityScopedResource() {
                logger.debug("Started accessing security-scoped resource: \(url.path, privacy: .private)")
            }
        }
    }

    func stopAccessing(_ urls: [URL]) {
        for url in urls {
            url.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: - Bookmarks

    private func createBookmark(for url: URL) -> Data? {
        do {
            return try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            logger.error("Failed to create bookmark for \(url.path, privacy: .private): \(error, privacy: .public)")
            return nil
        }
    }

    private func resolveBookmark(_ data: Data) -> URL? {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                logger.warning("Bookmark is stale for \(url.path, privacy: .private) — user may need to re-select")
            }
            return url
        } catch {
            logger.error("Failed to resolve bookmark: \(error, privacy: .public)")
            return nil
        }
    }

    // MARK: - Migration

    private func migrateLegacyPathsIfNeeded() {
        guard let paths = defaults.stringArray(forKey: Self.legacyKey) else { return }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let bookmarks = urls.compactMap { createBookmark(for: $0) }
        if !bookmarks.isEmpty {
            defaults.set(bookmarks, forKey: Self.key)
            logger.info("Migrated \(bookmarks.count, privacy: .public) directory bookmark(s) from legacy storage")
        }
        defaults.removeObject(forKey: Self.legacyKey)
    }
}
