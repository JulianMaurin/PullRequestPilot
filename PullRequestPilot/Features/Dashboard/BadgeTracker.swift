import Foundation

@MainActor
@Observable
final class BadgeTracker {

    // MARK: - Properties

    private(set) var enabledViewIDs: Set<String> = []
    private(set) var unseenPRIDs: Set<String> = []
    var onCountChanged: ((Int) -> Void)?

    /// Baseline PR IDs per view — used to detect newly added PRs.
    /// Shared with notification delivery so the first fetch doesn't
    /// trigger a notification flood.
    private var previousPRIDs: [UUID: Set<String>] = [:]
    private var completedInitialLoad: Set<UUID> = []
    private let defaults: UserDefaults

    var count: Int { unseenPRIDs.count }

    // MARK: - Init

    init(defaults: UserDefaults) {
        self.defaults = defaults
        self.enabledViewIDs = Set(defaults.stringArray(forKey: Constants.UserDefaultsKeys.badgeViewIDs) ?? [])
    }

    // MARK: - Public

    func isEnabled(for viewID: UUID) -> Bool {
        enabledViewIDs.contains(viewID.uuidString)
    }

    func setEnabled(for viewID: UUID, enabled: Bool, currentPRs: [PullRequest]) {
        if enabled {
            enabledViewIDs.insert(viewID.uuidString)
            if previousPRIDs[viewID] == nil, !currentPRs.isEmpty {
                previousPRIDs[viewID] = Set(currentPRs.map(\.id))
                completedInitialLoad.insert(viewID)
            }
        } else {
            enabledViewIDs.remove(viewID.uuidString)
            previousPRIDs.removeValue(forKey: viewID)
            completedInitialLoad.remove(viewID)
        }
        persistEnabledViewIDs()
        notifyCount()
    }

    func markAsSeen() {
        guard !unseenPRIDs.isEmpty else { return }
        unseenPRIDs.removeAll()
        notifyCount()
    }

    func markAsSeen(prIDs: Set<String>) {
        let removed = unseenPRIDs.intersection(prIDs)
        guard !removed.isEmpty else { return }
        unseenPRIDs.subtract(removed)
        notifyCount()
    }

    /// Computes the set of newly added PR IDs for a view by comparing
    /// against the previous snapshot. Returns empty on the first call
    /// (initial load baseline).
    func detectNewPRs(viewID: UUID, currentPRs: [PullRequest]) -> Set<String> {
        let currentIDs = Set(currentPRs.map(\.id))

        guard completedInitialLoad.contains(viewID) else {
            previousPRIDs[viewID] = currentIDs
            completedInitialLoad.insert(viewID)
            return []
        }

        let previousIDs = previousPRIDs[viewID] ?? []
        let addedIDs = currentIDs.subtracting(previousIDs)
        previousPRIDs[viewID] = currentIDs
        return addedIDs
    }

    func trackUnseen(_ addedIDs: Set<String>) {
        unseenPRIDs.formUnion(addedIDs)
        notifyCount()
    }

    /// Removes unseen PR IDs that no longer appear in any badge-enabled view.
    func pruneUnseen(viewStates: [UUID: ViewState]) {
        guard !unseenPRIDs.isEmpty else { return }
        var allCurrentIDs = Set<String>()
        for viewIDString in enabledViewIDs {
            guard let uuid = UUID(uuidString: viewIDString) else { continue }
            let prs = viewStates[uuid]?.pullRequests ?? []
            allCurrentIDs.formUnion(prs.map(\.id))
        }
        let pruned = unseenPRIDs.intersection(allCurrentIDs)
        if pruned.count != unseenPRIDs.count {
            unseenPRIDs = pruned
            notifyCount()
        }
    }

    func removeView(id: UUID) {
        enabledViewIDs.remove(id.uuidString)
        persistEnabledViewIDs()
        previousPRIDs.removeValue(forKey: id)
        completedInitialLoad.remove(id)
    }

    func reset() {
        enabledViewIDs = []
        unseenPRIDs = []
        previousPRIDs = [:]
        completedInitialLoad = []
        persistEnabledViewIDs()
        notifyCount()
    }

    // MARK: - Private

    private func persistEnabledViewIDs() {
        defaults.set(Array(enabledViewIDs), forKey: Constants.UserDefaultsKeys.badgeViewIDs)
    }

    private func notifyCount() {
        onCountChanged?(count)
    }
}
