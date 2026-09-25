import Testing
import Foundation
@testable import PullRequestPilot

@Suite("ViewsStore")
@MainActor
struct ViewsStoreTests {
    private func makeStore(suiteName: String) throws -> ViewsStore {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return ViewsStore(defaults: defaults)
    }

    @Test("load returns empty array when no data exists")
    func loadReturnsDefaults() throws {
        let store = try makeStore(suiteName: "ViewsStoreEmpty")
        let views = store.load()
        #expect(views.isEmpty)
    }

    @Test("save and load round-trips views")
    func saveAndLoadRoundTrip() throws {
        let store = try makeStore(suiteName: "ViewsStoreRoundTrip")
        let views = [
            DashboardView(id: UUID(), title: "My PRs", query: "is:pr author:@me"),
            DashboardView(id: UUID(), title: "Team", query: "is:pr org:team", hideReviewed: true),
        ]
        store.save(views)

        let loaded = store.load()
        #expect(loaded.count == 2)
        #expect(loaded[0].title == "My PRs")
        #expect(loaded[1].title == "Team")
        #expect(loaded[1].hideReviewed == true)
    }

    @Test("load returns empty array when saved array is empty")
    func loadReturnsDefaultsForEmptyArray() throws {
        let store = try makeStore(suiteName: "ViewsStoreEmptyArray")
        store.save([])

        let loaded = store.load()
        #expect(loaded.isEmpty)
    }

    @Test("save overwrites previous data")
    func saveOverwrites() throws {
        let store = try makeStore(suiteName: "ViewsStoreOverwrite")
        store.save([DashboardView(id: UUID(), title: "First", query: "q1")])
        store.save([DashboardView(id: UUID(), title: "Second", query: "q2")])

        let loaded = store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.title == "Second")
    }

    @Test("load returns defaults when data is corrupted and surfaces a decodeCorruption event")
    func loadCorruptedData() async throws {
        let suiteName = "ViewsStoreCorrupted"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let center = EventCenter()
        let store = ViewsStore(defaults: defaults, reporter: center.reporter())

        defaults.set(Data("not valid json".utf8), forKey: "dashboard_views")

        let views = store.load()
        #expect(views.isEmpty)

        for _ in 0..<20 where center.events.isEmpty {
            await Task.yield()
        }

        guard case .error(let error) = center.events.first?.payload,
              case .decodeCorruption(let subsystem, _) = error
        else {
            Issue.record("Expected decodeCorruption event, got \(String(describing: center.events.first))")
            return
        }
        #expect(subsystem == "dashboard views")
    }

    @Test("corrupted load writes a backup file and posts a decodeCorruption event")
    func corruptedLoadBacksUpAndPosts() async throws {
        let suiteName = "ViewsStoreCorruptionBackup"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let center = EventCenter()
        let store = ViewsStore(defaults: defaults, reporter: center.reporter())

        defaults.set(Data("{garbage".utf8), forKey: "dashboard_views")

        let views = store.load()
        #expect(views.isEmpty)

        // Reporter hops through Task { @MainActor } — yield until the post lands.
        for _ in 0..<20 where center.events.isEmpty {
            await Task.yield()
        }

        guard case .error(let error) = center.events.first?.payload,
              case .decodeCorruption(let subsystem, let backupPath) = error
        else {
            Issue.record("Expected decodeCorruption event, got \(String(describing: center.events.first))")
            return
        }
        #expect(subsystem == "dashboard views")
        let path = try #require(backupPath)
        #expect(FileManager.default.fileExists(atPath: path))
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test("successful load after a corrupted load does not post a second decodeCorruption event")
    func loadErrorClearedOnSuccess() async throws {
        let suiteName = "ViewsStoreErrorClear"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let center = EventCenter()
        let store = ViewsStore(defaults: defaults, reporter: center.reporter())

        defaults.set(Data("bad".utf8), forKey: "dashboard_views")
        _ = store.load()
        for _ in 0..<20 where center.events.isEmpty {
            await Task.yield()
        }
        let firstEventCount = center.events.count
        #expect(firstEventCount == 1)

        store.save([DashboardView(id: UUID(), title: "Valid", query: "q")])
        let views = store.load()
        #expect(views.count == 1)

        for _ in 0..<20 { await Task.yield() }
        #expect(center.events.count == firstEventCount)
    }
}
