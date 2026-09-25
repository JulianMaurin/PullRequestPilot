import Testing
import Foundation
@testable import PullRequestPilot

@Suite("ViewRegistry")
struct ViewRegistryTests {

    // MARK: - Helpers

    /// In-memory ViewsStore for tests. Avoids UserDefaults round-trip for
    /// the stored views array so we can focus on ViewRegistry's own
    /// invariants. The `selectedViewID` persistence still goes through the
    /// injected UserDefaults, which is what we want to verify.
    @MainActor
    final class InMemoryViewsStore: ViewsStoreProtocol {
        var storedViews: [DashboardView]
        init(initial: [DashboardView] = []) { self.storedViews = initial }
        func load() -> [DashboardView] { storedViews }
        func save(_ views: [DashboardView]) { storedViews = views }
    }

    private static func isolatedDefaults(_ suiteName: String = #function) throws -> UserDefaults {
        let sanitized = suiteName.replacingOccurrences(of: "()", with: "")
        let defaults = try #require(UserDefaults(suiteName: "ViewRegistryTests.\(sanitized)"))
        defaults.removePersistentDomain(forName: "ViewRegistryTests.\(sanitized)")
        return defaults
    }

    @MainActor
    private static func makeRegistry(initial: [DashboardView] = [], defaults: UserDefaults) -> (ViewRegistry, InMemoryViewsStore) {
        let store = InMemoryViewsStore(initial: initial)
        let registry = ViewRegistry(viewsStore: store, defaults: defaults)
        return (registry, store)
    }

    private static func makeView(_ title: String) -> DashboardView {
        DashboardView(id: UUID(), title: title, query: "is:pr author:@me")
    }

    // MARK: - Init + load

    @MainActor
    @Test("init with empty store yields empty views and nil selection")
    func initEmpty() throws {
        let defaults = try Self.isolatedDefaults()
        let (registry, _) = Self.makeRegistry(defaults: defaults)
        #expect(registry.views.isEmpty)
        #expect(registry.selectedViewID == nil)
    }

    @MainActor
    @Test("init selects the first view when no selection is persisted")
    func initSelectsFirstView() throws {
        let defaults = try Self.isolatedDefaults()
        let v1 = Self.makeView("A")
        let v2 = Self.makeView("B")
        let (registry, _) = Self.makeRegistry(initial: [v1, v2], defaults: defaults)
        #expect(registry.selectedViewID == v1.id)
    }

    // MARK: - add / update / delete

    @MainActor
    @Test("addView appends to the registry and persists")
    func addAppends() throws {
        let defaults = try Self.isolatedDefaults()
        let (registry, store) = Self.makeRegistry(defaults: defaults)
        let v = Self.makeView("New")
        registry.addView(v)
        #expect(registry.views.count == 1)
        #expect(store.storedViews.count == 1)
        #expect(store.storedViews[0].id == v.id)
    }

    @MainActor
    @Test("addView to empty registry auto-selects the new view")
    func addAutoSelects() throws {
        let defaults = try Self.isolatedDefaults()
        let (registry, _) = Self.makeRegistry(defaults: defaults)
        let v = Self.makeView("New")
        registry.addView(v)
        #expect(registry.selectedViewID == v.id)
    }

    @MainActor
    @Test("addView does not change selection when one is already selected")
    func addDoesNotChangeSelection() throws {
        let defaults = try Self.isolatedDefaults()
        let existing = Self.makeView("A")
        let (registry, _) = Self.makeRegistry(initial: [existing], defaults: defaults)
        let originalSelection = registry.selectedViewID
        let newView = Self.makeView("B")
        registry.addView(newView)
        #expect(registry.selectedViewID == originalSelection)
    }

    @MainActor
    @Test("updateView mutates in place and persists")
    func updateMutates() throws {
        let defaults = try Self.isolatedDefaults()
        let v = Self.makeView("Original")
        let (registry, store) = Self.makeRegistry(initial: [v], defaults: defaults)
        let updated = DashboardView(id: v.id, title: "Updated", query: "is:open")
        registry.updateView(updated)
        let first = try #require(registry.views.first)
        #expect(first.title == "Updated")
        #expect(first.query == "is:open")
        let stored = try #require(store.storedViews.first)
        #expect(stored.title == "Updated")
    }

    @MainActor
    @Test("updateView is a no-op when the ID does not exist")
    func updateUnknownID() throws {
        let defaults = try Self.isolatedDefaults()
        let existing = Self.makeView("A")
        let (registry, _) = Self.makeRegistry(initial: [existing], defaults: defaults)
        let ghost = DashboardView(id: UUID(), title: "Ghost", query: "x")
        registry.updateView(ghost)
        #expect(registry.views.count == 1)
        #expect(registry.views[0].title == "A")
    }

    @MainActor
    @Test("deleteView removes and re-selects the next available view")
    func deleteReselects() throws {
        let defaults = try Self.isolatedDefaults()
        let a = Self.makeView("A")
        let b = Self.makeView("B")
        let (registry, _) = Self.makeRegistry(initial: [a, b], defaults: defaults)
        registry.selectedViewID = a.id
        let removed = registry.deleteView(id: a.id)
        #expect(removed)
        #expect(registry.views.count == 1)
        #expect(registry.selectedViewID == b.id)
    }

    @MainActor
    @Test("deleteView clears selection when last view is deleted")
    func deleteLastClearsSelection() throws {
        let defaults = try Self.isolatedDefaults()
        let a = Self.makeView("only")
        let (registry, _) = Self.makeRegistry(initial: [a], defaults: defaults)
        _ = registry.deleteView(id: a.id)
        #expect(registry.views.isEmpty)
        #expect(registry.selectedViewID == nil)
    }

    @MainActor
    @Test("deleteView returns false for unknown ID")
    func deleteUnknownReturnsFalse() throws {
        let defaults = try Self.isolatedDefaults()
        let a = Self.makeView("A")
        let (registry, _) = Self.makeRegistry(initial: [a], defaults: defaults)
        let removed = registry.deleteView(id: UUID())
        #expect(removed == false)
        #expect(registry.views.count == 1)
    }

    // MARK: - move

    @MainActor
    @Test("moveView reorders forward")
    func moveForward() throws {
        let defaults = try Self.isolatedDefaults()
        let a = Self.makeView("A")
        let b = Self.makeView("B")
        let c = Self.makeView("C")
        let (registry, _) = Self.makeRegistry(initial: [a, b, c], defaults: defaults)
        registry.moveView(from: a.id, to: c.id)
        #expect(registry.views.map(\.title) == ["B", "C", "A"])
    }

    @MainActor
    @Test("moveView reorders backward")
    func moveBackward() throws {
        let defaults = try Self.isolatedDefaults()
        let a = Self.makeView("A")
        let b = Self.makeView("B")
        let c = Self.makeView("C")
        let (registry, _) = Self.makeRegistry(initial: [a, b, c], defaults: defaults)
        registry.moveView(from: c.id, to: a.id)
        #expect(registry.views.map(\.title) == ["C", "A", "B"])
    }

    @MainActor
    @Test("moveView to the same position is a no-op")
    func moveSelfIsNoop() throws {
        let defaults = try Self.isolatedDefaults()
        let a = Self.makeView("A")
        let b = Self.makeView("B")
        let (registry, _) = Self.makeRegistry(initial: [a, b], defaults: defaults)
        registry.moveView(from: a.id, to: a.id)
        #expect(registry.views.map(\.title) == ["A", "B"])
    }

    // MARK: - navigation

    @MainActor
    @Test("selectNext wraps around")
    func selectNextWraps() throws {
        let defaults = try Self.isolatedDefaults()
        let a = Self.makeView("A")
        let b = Self.makeView("B")
        let (registry, _) = Self.makeRegistry(initial: [a, b], defaults: defaults)
        registry.selectedViewID = b.id
        registry.selectNext()
        #expect(registry.selectedViewID == a.id)
    }

    @MainActor
    @Test("selectPrevious wraps around")
    func selectPreviousWraps() throws {
        let defaults = try Self.isolatedDefaults()
        let a = Self.makeView("A")
        let b = Self.makeView("B")
        let (registry, _) = Self.makeRegistry(initial: [a, b], defaults: defaults)
        registry.selectedViewID = a.id
        registry.selectPrevious()
        #expect(registry.selectedViewID == b.id)
    }

    // MARK: - persistence of selected view ID

    @MainActor
    @Test("selectedViewID persists across registry instances")
    func selectedViewIDPersists() throws {
        let defaults = try Self.isolatedDefaults()
        let a = Self.makeView("A")
        let b = Self.makeView("B")
        let store = InMemoryViewsStore(initial: [a, b])
        let first = ViewRegistry(viewsStore: store, defaults: defaults)
        first.selectedViewID = b.id
        // New instance with the same defaults + store should restore B.
        let second = ViewRegistry(viewsStore: store, defaults: defaults)
        #expect(second.selectedViewID == b.id)
    }

    @MainActor
    @Test("stored selectedViewID is ignored when the view no longer exists")
    func selectedViewIDFallsBackToFirst() throws {
        let defaults = try Self.isolatedDefaults()
        defaults.set(UUID().uuidString, forKey: Constants.UserDefaultsKeys.selectedViewID)
        let a = Self.makeView("A")
        let store = InMemoryViewsStore(initial: [a])
        let registry = ViewRegistry(viewsStore: store, defaults: defaults)
        // The stored UUID doesn't match any loaded view → fall back to first.
        #expect(registry.selectedViewID == a.id)
    }

    // MARK: - clear

    @MainActor
    @Test("clear wipes views, selection, and persisted selection")
    func clearWipesEverything() throws {
        let defaults = try Self.isolatedDefaults()
        let a = Self.makeView("A")
        let store = InMemoryViewsStore(initial: [a])
        let registry = ViewRegistry(viewsStore: store, defaults: defaults)
        registry.selectedViewID = a.id
        registry.clear()
        #expect(registry.views.isEmpty)
        #expect(registry.selectedViewID == nil)
        #expect(store.storedViews.isEmpty)
        #expect(defaults.string(forKey: Constants.UserDefaultsKeys.selectedViewID) == nil)
    }

    // MARK: - replaceAll + reload

    @MainActor
    @Test("replaceAll re-selects first when current selection is absent")
    func replaceAllReselects() throws {
        let defaults = try Self.isolatedDefaults()
        let a = Self.makeView("A")
        let (registry, _) = Self.makeRegistry(initial: [a], defaults: defaults)
        registry.selectedViewID = a.id
        let b = Self.makeView("B")
        let c = Self.makeView("C")
        registry.replaceAll(with: [b, c])
        #expect(registry.views.map(\.title) == ["B", "C"])
        #expect(registry.selectedViewID == b.id)
    }

    @MainActor
    @Test("replaceAll keeps selection when the selected view survives")
    func replaceAllKeepsSelection() throws {
        let defaults = try Self.isolatedDefaults()
        let a = Self.makeView("A")
        let b = Self.makeView("B")
        let (registry, _) = Self.makeRegistry(initial: [a, b], defaults: defaults)
        registry.selectedViewID = b.id
        registry.replaceAll(with: [b])
        #expect(registry.selectedViewID == b.id)
    }
}
