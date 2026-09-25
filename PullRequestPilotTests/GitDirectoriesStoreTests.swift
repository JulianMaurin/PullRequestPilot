import Testing
import Foundation
@testable import PullRequestPilot

@Suite("GitDirectoriesStore")
@MainActor
struct GitDirectoriesStoreTests {

    private func makeStore(suiteName: String) throws -> (GitDirectoriesStore, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = GitDirectoriesStore(defaults: defaults)
        return (store, defaults)
    }

    // MARK: - Load / Save

    @Test("load returns empty array when no data exists")
    func loadReturnsEmpty() throws {
        let (store, _) = try makeStore(suiteName: "GDSEmpty")
        let dirs = store.load()
        #expect(dirs.isEmpty)
    }

    @Test("save and load round-trips with real directories")
    func saveAndLoadRoundTrip() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("gds-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let (store, _) = try makeStore(suiteName: "GDSRoundTrip")
        store.save([tmpDir])

        let loaded = store.load()
        #expect(loaded.count == 1)
        // Resolved URL may differ slightly from original (symlink resolution etc)
        #expect(loaded.first?.lastPathComponent == tmpDir.lastPathComponent)
    }

    // MARK: - saveFromPanel

    @Test("saveFromPanel appends bookmark to existing list")
    func saveFromPanelAppends() throws {
        let tmpDir1 = FileManager.default.temporaryDirectory.appendingPathComponent("gds-panel1-\(UUID().uuidString)")
        let tmpDir2 = FileManager.default.temporaryDirectory.appendingPathComponent("gds-panel2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmpDir2, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tmpDir1)
            try? FileManager.default.removeItem(at: tmpDir2)
        }

        let (store, _) = try makeStore(suiteName: "GDSPanel")
        let result1 = store.saveFromPanel(tmpDir1)
        #expect(result1 != nil)

        let result2 = store.saveFromPanel(tmpDir2)
        #expect(result2 != nil)

        let loaded = store.load()
        #expect(loaded.count == 2)
    }

    @Test("saveFromPanel returns nil for nonexistent directory")
    func saveFromPanelNonexistent() throws {
        let (store, _) = try makeStore(suiteName: "GDSPanelNonexist")
        let result = store.saveFromPanel(URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"))
        #expect(result == nil)
    }

    // MARK: - Security-Scoped Access

    @Test("load starts access once per directory and stopAccessing balances it")
    func accessIsStartedOnceAndBalanced() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("gds-access-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let (store, _) = try makeStore(suiteName: "GDSAccess")
        store.save([tmpDir])

        let urls = store.load()
        #expect(urls.count == 1)
        #expect(store.startedURLs == Set(urls))
        store.startAccessing(urls)
        #expect(store.startedURLs == Set(urls), "a second start must not stack another access count")

        store.stopAccessing(urls)
        #expect(store.startedURLs.isEmpty)
    }

    @Test("stopAccessing ignores directories it never started")
    func stopWithoutStartIsIgnored() throws {
        let (store, _) = try makeStore(suiteName: "GDSAccessEmpty")
        store.stopAccessing([FileManager.default.temporaryDirectory])
        #expect(store.startedURLs.isEmpty)
    }

    // MARK: - Legacy Migration

    @Test("migrateLegacyPathsIfNeeded converts string paths to bookmarks")
    func legacyMigration() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("gds-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let suiteName = "GDSLegacy"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        // Write legacy data before constructing the store (migration happens in init)
        defaults.set([tmpDir.path], forKey: "git_directories")

        let store = GitDirectoriesStore(defaults: defaults)

        // Legacy key should be removed
        #expect(defaults.stringArray(forKey: "git_directories") == nil)

        // New bookmark data should exist
        let loaded = store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.lastPathComponent == tmpDir.lastPathComponent)
    }

    @Test("migrateLegacyPathsIfNeeded is no-op when no legacy data")
    func legacyMigrationNoOp() throws {
        let (store, defaults) = try makeStore(suiteName: "GDSLegacyNoOp")
        // No legacy key set — migration should be a no-op
        #expect(defaults.stringArray(forKey: "git_directories") == nil)
        let loaded = store.load()
        #expect(loaded.isEmpty)
        _ = store // keep alive
    }

    // MARK: - Unavailable and stale bookmarks

    private func makeTemporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gds-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func storedBookmarkCount(_ defaults: UserDefaults) -> Int {
        (defaults.array(forKey: "git_directory_bookmarks") as? [Data])?.count ?? 0
    }

    @Test("an unresolvable bookmark is kept, listed and reported instead of deleted")
    func unavailableBookmarkIsKept() throws {
        let directory = try makeTemporaryDirectory("unavailable")
        let (seedStore, defaults) = try makeStore(suiteName: "GDSUnavailable")
        #expect(seedStore.saveFromPanel(directory) != nil)
        try FileManager.default.removeItem(at: directory)

        let recorder = EventRecorder()
        let store = GitDirectoriesStore(defaults: defaults, reporter: recorder.reporter())
        let loaded = store.load()

        #expect(loaded.isEmpty)
        #expect(storedBookmarkCount(defaults) == 1)
        #expect(store.unavailableDirectoryPaths.count == 1)
        #expect(store.unavailableDirectoryPaths.first?.hasSuffix(directory.lastPathComponent) == true)
        #expect(recorder.unresolvedErrors == [.gitDirectoriesUnavailable(count: 1)])

        // Unchanged availability on the next load doesn't re-post.
        _ = store.load()
        #expect(recorder.events.count == 1)
    }

    @Test("a directory that comes back is used again and its warning resolves")
    func unavailableBookmarkRecovers() throws {
        let directory = try makeTemporaryDirectory("recovers")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (seedStore, defaults) = try makeStore(suiteName: "GDSRecovers")
        #expect(seedStore.saveFromPanel(directory) != nil)
        try FileManager.default.removeItem(at: directory)

        let recorder = EventRecorder()
        let store = GitDirectoriesStore(defaults: defaults, reporter: recorder.reporter())
        #expect(store.load().isEmpty)
        #expect(recorder.unresolvedErrors.count == 1)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let loaded = store.load()

        #expect(loaded.map(\.lastPathComponent) == [directory.lastPathComponent])
        #expect(store.unavailableDirectoryPaths.isEmpty)
        #expect(recorder.unresolvedErrors.isEmpty)
    }

    @Test("a stale bookmark to a moved directory is refreshed in storage")
    func staleBookmarkIsRefreshed() throws {
        let original = try makeTemporaryDirectory("stale")
        let moved = original.deletingLastPathComponent().appendingPathComponent("gds-moved-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: moved) }
        let (store, defaults) = try makeStore(suiteName: "GDSStale")
        #expect(store.saveFromPanel(original) != nil)
        let bookmarkBefore = try #require((defaults.array(forKey: "git_directory_bookmarks") as? [Data])?.first)

        try FileManager.default.moveItem(at: original, to: moved)
        let loaded = store.load()

        #expect(loaded.map(\.lastPathComponent) == [moved.lastPathComponent])
        #expect(store.unavailableDirectoryPaths.isEmpty)
        let bookmarkAfter = try #require((defaults.array(forKey: "git_directory_bookmarks") as? [Data])?.first)
        #expect(bookmarkAfter != bookmarkBefore)
    }

    @Test("saving the available list keeps unavailable bookmarks")
    func saveKeepsUnavailableBookmarks() throws {
        let gone = try makeTemporaryDirectory("gone")
        let present = try makeTemporaryDirectory("present")
        defer { try? FileManager.default.removeItem(at: present) }
        let (store, defaults) = try makeStore(suiteName: "GDSSaveKeeps")
        store.save([gone, present])
        try FileManager.default.removeItem(at: gone)

        let available = store.load()
        store.save(available)

        #expect(storedBookmarkCount(defaults) == 2)
        #expect(store.load().map(\.lastPathComponent) == [present.lastPathComponent])
    }

    @Test("removing an unavailable directory deletes only its bookmark")
    func removeUnavailableDirectory() throws {
        let gone = try makeTemporaryDirectory("remove-gone")
        let present = try makeTemporaryDirectory("remove-present")
        defer { try? FileManager.default.removeItem(at: present) }
        let (seedStore, defaults) = try makeStore(suiteName: "GDSRemoveUnavailable")
        seedStore.save([gone, present])
        try FileManager.default.removeItem(at: gone)

        let recorder = EventRecorder()
        let store = GitDirectoriesStore(defaults: defaults, reporter: recorder.reporter())
        _ = store.load()
        let path = try #require(store.unavailableDirectoryPaths.first)
        store.removeUnavailableDirectory(atPath: path)

        #expect(storedBookmarkCount(defaults) == 1)
        #expect(store.unavailableDirectoryPaths.isEmpty)
        #expect(recorder.unresolvedErrors.isEmpty)
        #expect(store.load().map(\.lastPathComponent) == [present.lastPathComponent])
    }

    // MARK: - Corruption

    @Test("a stored value of the wrong type is backed up, reported and cleared")
    func corruptedBookmarksAreBackedUp() async throws {
        let suiteName = "GDSCorrupted"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("not a bookmark list", forKey: "git_directory_bookmarks")
        let backupDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("gds-backups-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: backupDirectory) }
        let recorder = EventRecorder()
        let store = GitDirectoriesStore(defaults: defaults, reporter: recorder.reporter(), backupDirectory: backupDirectory)

        #expect(store.load().isEmpty)

        guard case .decodeCorruption(let subsystem, let backupPath)? = recorder.unresolvedErrors.first else {
            Issue.record("Expected decodeCorruption, got \(recorder.unresolvedErrors)")
            return
        }
        #expect(subsystem == "git directories")
        let path = try #require(backupPath)
        #expect(path.hasPrefix(backupDirectory.path))
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(defaults.object(forKey: "git_directory_bookmarks") == nil)

        _ = store.load()
        #expect(recorder.events.count == 1, "a cleared value isn't reported again")
    }

    // MARK: - Save overwrite

    @Test("save replaces all previous bookmarks")
    func saveReplaces() throws {
        let tmpDir1 = FileManager.default.temporaryDirectory.appendingPathComponent("gds-replace1-\(UUID().uuidString)")
        let tmpDir2 = FileManager.default.temporaryDirectory.appendingPathComponent("gds-replace2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmpDir2, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tmpDir1)
            try? FileManager.default.removeItem(at: tmpDir2)
        }

        let (store, _) = try makeStore(suiteName: "GDSReplace")
        store.save([tmpDir1, tmpDir2])
        #expect(store.load().count == 2)

        store.save([tmpDir1])
        #expect(store.load().count == 1)
    }
}
