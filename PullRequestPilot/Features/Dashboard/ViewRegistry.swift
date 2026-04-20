import Foundation

@MainActor
@Observable
final class ViewRegistry {

    // MARK: - Properties

    private(set) var views: [DashboardView]
    var selectedViewID: UUID? {
        didSet { persistSelectedViewID() }
    }

    private let viewsStore: any ViewsStoreProtocol
    private let defaults: UserDefaults

    // MARK: - Init

    init(viewsStore: any ViewsStoreProtocol, defaults: UserDefaults) {
        self.viewsStore = viewsStore
        self.defaults = defaults
        let loaded = viewsStore.load()
        self.views = loaded
        self.selectedViewID = Self.restoreSelectedViewID(from: defaults, views: loaded)
    }

    // MARK: - Mutations

    func addView(_ view: DashboardView) {
        views.append(view)
        viewsStore.save(views)
        if selectedViewID == nil {
            selectedViewID = view.id
        }
    }

    func updateView(_ view: DashboardView) {
        guard let index = views.firstIndex(where: { $0.id == view.id }) else { return }
        views[index] = view
        viewsStore.save(views)
    }

    @discardableResult
    func deleteView(id: UUID) -> Bool {
        let countBefore = views.count
        views.removeAll { $0.id == id }
        guard views.count != countBefore else { return false }
        viewsStore.save(views)
        if selectedViewID == id {
            selectedViewID = views.first?.id
        }
        return true
    }

    func moveView(from sourceID: UUID, to targetID: UUID) {
        guard let sourceIndex = views.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = views.firstIndex(where: { $0.id == targetID }),
              sourceIndex != targetIndex else { return }
        views.move(fromOffsets: IndexSet(integer: sourceIndex),
                   toOffset: targetIndex > sourceIndex ? targetIndex + 1 : targetIndex)
        viewsStore.save(views)
    }

    func replaceAll(with newViews: [DashboardView]) {
        views = newViews
        viewsStore.save(newViews)
        if let selected = selectedViewID, !newViews.contains(where: { $0.id == selected }) {
            selectedViewID = newViews.first?.id
        } else if selectedViewID == nil {
            selectedViewID = newViews.first?.id
        }
    }

    func reload() {
        let loaded = viewsStore.load()
        replaceAll(with: loaded)
    }

    // MARK: - Navigation

    func selectNext() {
        guard let currentID = selectedViewID,
              let currentIndex = views.firstIndex(where: { $0.id == currentID }),
              !views.isEmpty else { return }
        selectedViewID = views[(currentIndex + 1) % views.count].id
    }

    func selectPrevious() {
        guard let currentID = selectedViewID,
              let currentIndex = views.firstIndex(where: { $0.id == currentID }),
              !views.isEmpty else { return }
        selectedViewID = views[(currentIndex - 1 + views.count) % views.count].id
    }

    func clear() {
        views = []
        viewsStore.save([])
        selectedViewID = nil
        defaults.removeObject(forKey: Constants.UserDefaultsKeys.selectedViewID)
    }

    // MARK: - Private

    private func persistSelectedViewID() {
        defaults.set(selectedViewID?.uuidString, forKey: Constants.UserDefaultsKeys.selectedViewID)
    }

    private static func restoreSelectedViewID(from defaults: UserDefaults, views: [DashboardView]) -> UUID? {
        guard let stored = defaults.string(forKey: Constants.UserDefaultsKeys.selectedViewID),
              let uuid = UUID(uuidString: stored),
              views.contains(where: { $0.id == uuid }) else {
            return views.first?.id
        }
        return uuid
    }
}
