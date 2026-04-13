import Testing
import Foundation
@testable import PullRequestPilot

@Suite("GitDirectoriesStore")
@MainActor
struct GitDirectoriesStoreTests {

    private func makeStore(suiteName: String) -> (GitDirectoriesStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = GitDirectoriesStore(defaults: defaults)
        return (store, defaults)
    }

    // MARK: - Load / Save

    @Test("load returns empty array when no data exists")
    func loadReturnsEmpty() {
        let (store, _) = makeStore(suiteName: "GDSEmpty")
        let dirs = store.load()
        #expect(dirs.isEmpty)
    }

    @Test("save and load round-trips with real directories")
    func saveAndLoadRoundTrip() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("gds-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let (store, _) = makeStore(suiteName: "GDSRoundTrip")
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

        let (store, _) = makeStore(suiteName: "GDSPanel")
        let result1 = store.saveFromPanel(tmpDir1)
        #expect(result1 != nil)

        let result2 = store.saveFromPanel(tmpDir2)
        #expect(result2 != nil)

        let loaded = store.load()
        #expect(loaded.count == 2)
    }

    @Test("saveFromPanel returns nil for nonexistent directory")
    func saveFromPanelNonexistent() {
        let (store, _) = makeStore(suiteName: "GDSPanelNonexist")
        let result = store.saveFromPanel(URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"))
        #expect(result == nil)
    }

    // MARK: - Security-Scoped Access

    @Test("startAccessing and stopAccessing don't crash")
    func accessingDoesNotCrash() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("gds-access-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let (store, _) = makeStore(suiteName: "GDSAccess")
        store.startAccessing([tmpDir])
        store.stopAccessing([tmpDir])
    }

    @Test("startAccessing with empty array is safe")
    func accessingEmptyArray() {
        let (store, _) = makeStore(suiteName: "GDSAccessEmpty")
        store.startAccessing([])
        store.stopAccessing([])
    }

    // MARK: - Legacy Migration

    @Test("migrateLegacyPathsIfNeeded converts string paths to bookmarks")
    func legacyMigration() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("gds-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let suiteName = "GDSLegacy"
        let defaults = UserDefaults(suiteName: suiteName)!
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
    func legacyMigrationNoOp() {
        let (store, defaults) = makeStore(suiteName: "GDSLegacyNoOp")
        // No legacy key set — migration should be a no-op
        #expect(defaults.stringArray(forKey: "git_directories") == nil)
        let loaded = store.load()
        #expect(loaded.isEmpty)
        _ = store // keep alive
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

        let (store, _) = makeStore(suiteName: "GDSReplace")
        store.save([tmpDir1, tmpDir2])
        #expect(store.load().count == 2)

        store.save([tmpDir1])
        #expect(store.load().count == 1)
    }
}
