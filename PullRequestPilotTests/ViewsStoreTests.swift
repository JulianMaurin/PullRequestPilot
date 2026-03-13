import Testing
import Foundation
@testable import PullRequestPilot

@Suite("ViewsStore")
struct ViewsStoreTests {
    private func makeStore(suiteName: String) -> ViewsStore {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return ViewsStore(defaults: defaults)
    }

    @Test("load returns empty array when no data exists")
    func loadReturnsDefaults() {
        let store = makeStore(suiteName: "ViewsStoreEmpty")
        let views = store.load()
        #expect(views.isEmpty)
    }

    @Test("save and load round-trips views")
    func saveAndLoadRoundTrip() {
        let store = makeStore(suiteName: "ViewsStoreRoundTrip")
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
    func loadReturnsDefaultsForEmptyArray() {
        let store = makeStore(suiteName: "ViewsStoreEmptyArray")
        store.save([])

        let loaded = store.load()
        #expect(loaded.isEmpty)
    }

    @Test("save overwrites previous data")
    func saveOverwrites() {
        let store = makeStore(suiteName: "ViewsStoreOverwrite")
        store.save([DashboardView(id: UUID(), title: "First", query: "q1")])
        store.save([DashboardView(id: UUID(), title: "Second", query: "q2")])

        let loaded = store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.title == "Second")
    }
}
