import Foundation
import Observation

/// The dashboard capabilities SettingsView needs. Settings owns the protocol
/// so it never names the Dashboard feature; `AppState` declares the
/// conformance.
@MainActor
protocol DashboardActionsProtocol: Observable, AnyObject {
    var views: [DashboardView] { get }
    var systemNotificationsAuthorized: Bool { get }
    func clearAllData()
    func startAutoRefresh()
    func refreshAll() async
    func refreshNotificationAuthorization() async
    func requestNotificationPermissionAndOpenSettings() async
    func addView(_ view: DashboardView)
    func updateView(_ view: DashboardView)
    func refresh(viewID: UUID) async
}
