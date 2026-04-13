import Foundation
import Observation

/// Defines the dashboard capabilities that SettingsView needs,
/// decoupling it from the concrete DashboardViewModel type.
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
