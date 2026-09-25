import Foundation
import Observation

/// The dashboard capabilities SettingsView needs. Settings owns the protocol
/// so it never names the Dashboard feature; `AppState` declares the
/// conformance.
@MainActor
protocol DashboardActionsProtocol: Observable, AnyObject {
    var views: [DashboardView] { get }
    var systemNotificationsAuthorized: Bool { get }
    func refreshNotificationAuthorization() async
    func requestNotificationPermissionAndOpenSettings() async
    func addPresetView(_ preset: DashboardView)
    func resetPresetView(_ preset: DashboardView)
}
