import AppKit
import Foundation
import os
import UserNotifications

@MainActor
@Observable
final class NotificationService {

    // MARK: - Properties

    private(set) var enabledViewIDs: Set<String> = []
    private(set) var systemAuthorized: Bool = false

    private let defaults: UserDefaults
    private let reporter: EventReporter
    private let logger: Logger

    // MARK: - Init

    init(defaults: UserDefaults, reporter: EventReporter = .noop) {
        self.defaults = defaults
        self.reporter = reporter
        self.logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PullRequestPilot", category: "Notifications")
        self.enabledViewIDs = Set(defaults.stringArray(forKey: Constants.UserDefaultsKeys.notifiedViewIDs) ?? [])
    }

    // MARK: - Public

    func isEnabled(for viewID: UUID) -> Bool {
        enabledViewIDs.contains(viewID.uuidString)
    }

    func setEnabled(for viewID: UUID, enabled: Bool) {
        if enabled {
            enabledViewIDs.insert(viewID.uuidString)
        } else {
            enabledViewIDs.remove(viewID.uuidString)
        }
        persistEnabledViewIDs()
    }

    func refreshAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        systemAuthorized = settings.authorizationStatus == .authorized
        if !systemAuthorized {
            enabledViewIDs = []
            persistEnabledViewIDs()
        }
    }

    func ensurePermission(for viewID: UUID) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()

        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = await requestPermission()
            systemAuthorized = granted
            if !granted {
                setEnabled(for: viewID, enabled: false)
            }
        case .denied:
            systemAuthorized = false
            setEnabled(for: viewID, enabled: false)
        case .authorized, .provisional, .ephemeral:
            systemAuthorized = true
        @unknown default:
            break
        }
    }

    func requestPermissionAndOpenSettings() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            let granted = await requestPermission()
            systemAuthorized = granted
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings") {
            NSWorkspace.shared.open(url)
        }
    }

    func deliver(viewTitle: String, viewID: UUID, addedPRs: [PullRequest]) async {
        // Skip delivering notifications during unit tests
        guard NSClassFromString("XCTestCase") == nil else { return }

        let content = UNMutableNotificationContent()
        content.title = viewTitle
        content.sound = .default

        if addedPRs.count == 1, let pr = addedPRs.first {
            content.subtitle = pr.repository.nameWithOwner
            content.body = "#\(pr.number) \(pr.title)"
        } else {
            let lines = addedPRs.prefix(4).map { "\($0.repository.nameWithOwner) #\($0.number) \($0.title)" }
            let remaining = addedPRs.count - lines.count
            let body = remaining > 0
                ? lines.joined(separator: "\n") + "\n+\(remaining) more"
                : lines.joined(separator: "\n")
            content.body = body
        }

        let request = UNNotificationRequest(
            identifier: "new-prs-\(viewID.uuidString)-\(Date.now.timeIntervalSince1970)",
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch is CancellationError {
            return
        } catch {
            logger.error("Failed to deliver notification: \(error, privacy: .public)")
            reporter.postError(.notificationSystemError(detail: error.localizedDescription))
        }
    }

    func removeView(id: UUID) {
        enabledViewIDs.remove(id.uuidString)
        persistEnabledViewIDs()
    }

    func reset() {
        enabledViewIDs = []
        persistEnabledViewIDs()
    }

    // MARK: - Private

    private func requestPermission() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch is CancellationError {
            // Cancellation isn't a permanent "denied" — callers re-query the
            // authorization status on the next attempt.
            return false
        } catch let error as UNError where error.code == .notificationsNotAllowed {
            // Equivalent to .denied. macOS can throw this from requestAuthorization
            // when notifications are blocked at system level (e.g., stale state from
            // a prior install — see scripts/nuke-notifications.sh). Don't surface as
            // a toast: callers (Settings "Open Settings" button, view toggle) are
            // already guiding the user to System Settings to fix it.
            logger.info("Notifications not allowed at system level — treating as denied")
            return false
        } catch {
            logger.error("Notification permission error: \(error, privacy: .public)")
            reporter.postError(.notificationSystemError(detail: error.localizedDescription))
            return false
        }
    }

    private func persistEnabledViewIDs() {
        defaults.set(Array(enabledViewIDs), forKey: Constants.UserDefaultsKeys.notifiedViewIDs)
    }
}
