import Foundation
import os

@MainActor
final class GitDirectoriesStore {
    private static let key = "git_directory_bookmarks"
    private static let legacyKey = "git_directories"
    /// Paths of stored bookmarks that didn't resolve on the last load (disk
    /// not mounted, folder moved or deleted). They stay stored and are retried
    /// on every load; only an explicit removal deletes them.
    private(set) var unavailableDirectoryPaths: [String] = []
    private let defaults: UserDefaults
    private let reporter: EventReporter
    /// Cached resolution of the stored bookmark array keyed by its data
    /// fingerprint. Invalidated whenever we mutate the stored array.
    private var cachedBookmarksFingerprint: [Data]?
    private var cachedURLs: [URL] = []
    /// URLs for which `startAccessingSecurityScopedResource()` actually
    /// returned `true`. Apple's docs require balancing only successful starts.
    private(set) var startedURLs: Set<URL> = []
    private let logger = Logger(category: "GitDirectoriesStore")

    /// Where an undecodable bookmark list is copied before it's cleared; nil
    /// when Application Support is unavailable.
    private let backupDirectory: URL?

    init(defaults: UserDefaults, reporter: EventReporter = .noop, backupDirectory: URL? = ViewsStore.applicationSupportDirectory()) {
        self.defaults = defaults
        self.reporter = reporter
        self.backupDirectory = backupDirectory
        migrateLegacyPathsIfNeeded()
    }

    // MARK: - Public

    /// Resolves every stored bookmark and starts security-scoped access for
    /// the directories that resolve; the access lasts for the app's lifetime
    /// so the periodic repository scan can read them.
    func load() -> [URL] {
        let bookmarksData = decodeStoredBookmarks()
        // Unavailable bookmarks bypass the cache so a remounted disk is
        // picked up by the next load.
        if let cached = cachedBookmarksFingerprint, cached == bookmarksData, unavailableDirectoryPaths.isEmpty {
            return cachedURLs
        }
        var storedBookmarks: [Data] = []
        var urls: [URL] = []
        var unavailablePaths: [String] = []
        for data in bookmarksData {
            switch resolveBookmark(data) {
            case .resolved(let url, let refreshedBookmark):
                storedBookmarks.append(refreshedBookmark ?? data)
                urls.append(url)
            case .unavailable:
                storedBookmarks.append(data)
                unavailablePaths.append(Self.storedPath(of: data))
            }
        }
        if storedBookmarks != bookmarksData {
            defaults.set(storedBookmarks, forKey: Self.key)
        }
        startAccessing(urls)
        reportAvailability(unavailablePaths, previouslyUnavailable: unavailableDirectoryPaths)
        unavailableDirectoryPaths = unavailablePaths
        cachedBookmarksFingerprint = storedBookmarks
        cachedURLs = urls
        return urls
    }

    /// Stores `directories` as the available set. Unavailable bookmarks are
    /// kept: they aren't in the list only because they didn't resolve.
    func save(_ directories: [URL]) {
        let existingBookmarks = defaults.array(forKey: Self.key) as? [Data] ?? []
        // Reuse existing bookmarks (and their security scope) rather than
        // re-creating them, which fails once security-scoped access expired.
        var bookmarkByPath: [String: Data] = [:]
        var unavailableBookmarks: [Data] = []
        for data in existingBookmarks {
            switch resolveBookmark(data) {
            case .resolved(let url, let refreshedBookmark):
                bookmarkByPath[url.path] = refreshedBookmark ?? data
            case .unavailable:
                unavailableBookmarks.append(data)
            }
        }

        let result = directories.compactMap { url -> Data? in
            bookmarkByPath[url.path] ?? createBookmark(for: url)
        }
        defaults.set(result + unavailableBookmarks, forKey: Self.key)
        cachedBookmarksFingerprint = nil
    }

    /// Deletes the stored bookmarks for an unavailable directory.
    func removeUnavailableDirectory(atPath path: String) {
        let existingBookmarks = defaults.array(forKey: Self.key) as? [Data] ?? []
        let kept = existingBookmarks.filter { data in
            guard Self.storedPath(of: data) == path else { return true }
            if case .resolved = resolveBookmark(data) { return true }
            return false
        }
        defaults.set(kept, forKey: Self.key)
        unavailableDirectoryPaths.removeAll { $0 == path }
        cachedBookmarksFingerprint = nil
        if unavailableDirectoryPaths.isEmpty {
            reporter.resolve { error in
                if case .gitDirectoriesUnavailable = error { return true }
                return false
            }
        }
    }

    func saveFromPanel(_ url: URL) -> URL? {
        guard let bookmarkData = createBookmark(for: url) else { return nil }
        // Deduplicate: check if this directory is already bookmarked
        let existing = defaults.array(forKey: Self.key) as? [Data] ?? []
        let existingPaths = Set(existing.compactMap(resolvedPath(of:)))
        guard !existingPaths.contains(url.path) else { return url }
        var updated = existing
        updated.append(bookmarkData)
        defaults.set(updated, forKey: Self.key)
        cachedBookmarksFingerprint = nil
        return url
    }

    // MARK: - Security-Scoped Access

    func startAccessing(_ urls: [URL]) {
        for url in urls where !startedURLs.contains(url) {
            if url.startAccessingSecurityScopedResource() {
                startedURLs.insert(url)
                logger.debug("Started accessing security-scoped resource: \(url.path, privacy: .private)")
            }
        }
    }

    func stopAccessing(_ urls: [URL]) {
        for url in urls where startedURLs.contains(url) {
            url.stopAccessingSecurityScopedResource()
            startedURLs.remove(url)
        }
    }

    // MARK: - Corruption handling

    /// Reads the raw stored bookmark array, reporting+backing up if the stored
    /// value is the wrong type (e.g. corrupted across versions). On corruption
    /// the entry is removed so subsequent reads do not re-report, and so the
    /// next `save` starts from a clean slate.
    private func decodeStoredBookmarks() -> [Data] {
        guard let raw = defaults.object(forKey: Self.key) else { return [] }
        if let bookmarks = raw as? [Data] { return bookmarks }
        let backupPath = backupCorruptedData(raw)
        logger.error("git_directory_bookmarks stored value is not [Data] (was \(String(describing: type(of: raw)), privacy: .public)). Backup: \(backupPath ?? "n/a", privacy: .public)")
        reporter.postError(.decodeCorruption(subsystem: "git directories", backupPath: backupPath))
        defaults.removeObject(forKey: Self.key)
        return []
    }

    private func backupCorruptedData(_ value: Any) -> String? {
        guard let supportDir = backupDirectory else { return nil }
        let filename = "git-directories.corrupted-\(ViewsStore.backupDateString()).plist"
        let url = supportDir.appendingPathComponent(filename)
        do {
            try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
            try data.write(to: url, options: .atomic)
            return url.path
        } catch {
            logger.error("Failed to write corruption backup: \(error, privacy: .public)")
            return nil
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

    private enum BookmarkResolution {
        /// `refreshedBookmark` replaces a stale bookmark in storage.
        case resolved(URL, refreshedBookmark: Data?)
        case unavailable
    }

    private func resolveBookmark(_ data: Data) -> BookmarkResolution {
        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            logger.warning("Directory bookmark unavailable (\(Self.storedPath(of: data), privacy: .private)): \(error, privacy: .public)")
            return .unavailable
        }
        guard isStale else { return .resolved(url, refreshedBookmark: nil) }
        // A stale bookmark still resolves (the folder was moved or renamed);
        // re-create it while this resolution's scope grants access.
        startAccessing([url])
        guard let refreshed = createBookmark(for: url) else {
            logger.warning("Stale bookmark for \(url.path, privacy: .private) couldn't be refreshed; keeping it")
            return .resolved(url, refreshedBookmark: nil)
        }
        logger.info("Refreshed stale bookmark for \(url.path, privacy: .private)")
        return .resolved(url, refreshedBookmark: refreshed)
    }

    private func resolvedPath(of data: Data) -> String? {
        guard case .resolved(let url, _) = resolveBookmark(data) else { return nil }
        return url.path
    }

    /// The path recorded in the bookmark, readable without resolving it.
    private static func storedPath(of data: Data) -> String {
        URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: data)?.path ?? "Unknown location"
    }

    /// Posts when the unavailable set changes; resolves the banner once
    /// everything is reachable again.
    private func reportAvailability(_ unavailablePaths: [String], previouslyUnavailable: [String]) {
        guard Set(unavailablePaths) != Set(previouslyUnavailable) else { return }
        if unavailablePaths.isEmpty {
            reporter.resolve { error in
                if case .gitDirectoriesUnavailable = error { return true }
                return false
            }
        } else {
            reporter.postError(.gitDirectoriesUnavailable(count: unavailablePaths.count))
        }
    }

    // MARK: - Migration

    private func migrateLegacyPathsIfNeeded() {
        guard let paths = defaults.stringArray(forKey: Self.legacyKey) else { return }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let bookmarks = urls.compactMap { createBookmark(for: $0) }
        if !bookmarks.isEmpty {
            let existing = defaults.array(forKey: Self.key) as? [Data] ?? []
            let existingPaths = Set(existing.compactMap(resolvedPath(of:)))
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
            cachedBookmarksFingerprint = nil
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
