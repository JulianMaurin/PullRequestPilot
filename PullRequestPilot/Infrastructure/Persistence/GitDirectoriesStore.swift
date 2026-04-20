import Foundation
import os

@MainActor
final class GitDirectoriesStore {
    private static let key = "git_directory_bookmarks"
    private static let legacyKey = "git_directories"
    private(set) var lastPrunedStaleCount = 0
    private let defaults: UserDefaults
    private let reporter: EventReporter
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "PullRequestPilot",
        category: "GitDirectoriesStore"
    )

    init(defaults: UserDefaults = .standard, reporter: EventReporter = .noop) {
        self.defaults = defaults
        self.reporter = reporter
        migrateLegacyPathsIfNeeded()
    }

    // MARK: - Public

    func load() -> [URL] {
        guard let bookmarksData = defaults.array(forKey: Self.key) as? [Data] else {
            return []
        }
        var validBookmarks: [Data] = []
        var urls: [URL] = []
        for data in bookmarksData {
            if let url = resolveBookmark(data) {
                validBookmarks.append(data)
                urls.append(url)
            }
        }
        // Prune stale or unresolvable bookmarks
        let prunedCount = bookmarksData.count - validBookmarks.count
        lastPrunedStaleCount = prunedCount
        if prunedCount > 0 {
            defaults.set(validBookmarks, forKey: Self.key)
            reporter.postError(.bookmarkPruned(count: prunedCount))
        }
        return urls
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
        // Deduplicate: check if this directory is already bookmarked
        let existing = defaults.array(forKey: Self.key) as? [Data] ?? []
        let existingPaths = Set(existing.compactMap { resolveBookmark($0)?.path })
        guard !existingPaths.contains(url.path) else { return url }
        var updated = existing
        updated.append(bookmarkData)
        defaults.set(updated, forKey: Self.key)
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
                logger.warning("Bookmark is stale for \(url.path, privacy: .private) — user must re-select the directory")
                return nil
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
            let existing = defaults.array(forKey: Self.key) as? [Data] ?? []
            let existingPaths = Set(existing.compactMap { resolveBookmark($0)?.path })
            let newBookmarks = zip(urls, bookmarks).compactMap { url, data in
                existingPaths.contains(url.path) ? nil : data
            }
            guard !newBookmarks.isEmpty else {
                // All paths already bookmarked — clean up legacy key
                defaults.removeObject(forKey: Self.legacyKey)
                return
            }
            var updated = existing
            updated.append(contentsOf: newBookmarks)
            defaults.set(updated, forKey: Self.key)
            logger.info("Migrated \(bookmarks.count, privacy: .public) directory bookmark(s) from legacy storage")
        }
        // Only remove legacy key if all paths were migrated successfully
        if bookmarks.count == paths.count {
            defaults.removeObject(forKey: Self.legacyKey)
        } else {
            logger.warning("Could not migrate \(paths.count - bookmarks.count, privacy: .public) legacy path(s) — legacy key retained for retry")
        }
    }
}
