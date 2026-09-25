import AppKit
import Foundation
import os
import UserNotifications

/// Where a notification leads when clicked: the view it announced, and the
/// pull request when it announced exactly one.
struct NotificationRoute: Equatable, Sendable {
    let viewID: UUID
    let pullRequestID: String?

    private static let viewIDKey = "viewID"
    private static let pullRequestIDKey = "pullRequestID"

    init(viewID: UUID, pullRequestID: String? = nil) {
        self.viewID = viewID
        self.pullRequestID = pullRequestID
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let rawViewID = userInfo[Self.viewIDKey] as? String,
              let viewID = UUID(uuidString: rawViewID)
        else { return nil }
        self.init(viewID: viewID, pullRequestID: userInfo[Self.pullRequestIDKey] as? String)
    }

    var userInfo: [String: String] {
        var info = [Self.viewIDKey: viewID.uuidString]
        info[Self.pullRequestIDKey] = pullRequestID
        return info
    }
}

@MainActor
@Observable
final class NotificationService {

    // MARK: - Properties

    /// The views whose bell the user turned on. System authorization never
    /// changes it: a bell turned on while notifications are off in System
    /// Settings stays on and alerts once they're back.
    private(set) var enabledViewIDs: Set<String> = []
    /// nil until the first check.
    private(set) var systemAuthorizationStatus: UNAuthorizationStatus?

    var systemAuthorized: Bool {
        switch systemAuthorizationStatus {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }

    /// Notifications are off for the app in System Settings: enabled bells
    /// can't alert.
    var systemDenied: Bool { systemAuthorizationStatus == .denied }

    static let deniedExplanation = "Notifications are off for Pull Request Pilot in System Settings, so bells can't alert you. Turn them on from Settings › Notifications."

    private let defaults: UserDefaults
    private let center: any UserNotificationCenterProtocol
    private let reporter: EventReporter
    private let logger = Logger(category: "Notifications")

    // MARK: - Init

    init(defaults: UserDefaults, center: any UserNotificationCenterProtocol, reporter: EventReporter = .noop) {
        self.defaults = defaults
        self.center = center
        self.reporter = reporter
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
        systemAuthorizationStatus = await center.authorizationStatus()
    }

    /// Called when a bell turns on: asks for permission the first time, and
    /// explains a denial instead of turning the bell back off.
    func ensurePermission() async {
        var status = await center.authorizationStatus()
        if status == .notDetermined {
            _ = await requestPermission()
            status = await center.authorizationStatus()
        }
        systemAuthorizationStatus = status
        if status == .denied {
            reporter.postWarning(Self.deniedExplanation)
        }
    }

    func requestPermissionAndOpenSettings() async {
        if await center.authorizationStatus() == .notDetermined {
            _ = await requestPermission()
        }
        systemAuthorizationStatus = await center.authorizationStatus()
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings") {
            NSWorkspace.shared.open(url)
        }
    }

    func deliver(viewTitle: String, viewID: UUID, addedPRs: [PullRequest]) async {
        let status = await center.authorizationStatus()
        systemAuthorizationStatus = status
        guard systemAuthorized else {
            logger.info("Skipping a notification: not authorized in System Settings")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = viewTitle
        content.sound = .default
        // Notification Center groups each view's notifications together.
        content.threadIdentifier = viewID.uuidString
        let announcedPullRequestID = addedPRs.count == 1 ? addedPRs.first?.id : nil
        content.userInfo = NotificationRoute(viewID: viewID, pullRequestID: announcedPullRequestID).userInfo

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
            try await center.add(request)
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
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            return handlePermissionError(error)
        }
    }

    /// Pure classifier for errors thrown by `requestAuthorization`. Returns
    /// `false` (treat as denied) for cancellation and the macOS-level
    /// `notificationsNotAllowed` case (which surfaces when notifications are
    /// blocked system-wide — see scripts/nuke-notifications.sh). Any other
    /// error produces a user-visible toast. Exposed `internal` so tests can
    /// pin the suppression behaviour without spinning up UNUserNotificationCenter.
    func handlePermissionError(_ error: any Error) -> Bool {
        if error is CancellationError {
            return false
        }
        if let unError = error as? UNError, unError.code == .notificationsNotAllowed {
            logger.info("Notifications not allowed at system level — treating as denied")
            return false
        }
        logger.error("Notification permission error: \(error, privacy: .public)")
        reporter.postError(.notificationSystemError(detail: error.localizedDescription))
        return false
    }

    private func persistEnabledViewIDs() {
        defaults.set(Array(enabledViewIDs), forKey: Constants.UserDefaultsKeys.notifiedViewIDs)
    }
}
