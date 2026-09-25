import UserNotifications

/// The part of `UNUserNotificationCenter` the app uses. Tests pass a double so
/// they can drive authorization and read deliveries without touching the
/// user's Notification Center.
@MainActor
protocol UserNotificationCenterProtocol {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
}

@MainActor
struct SystemUserNotificationCenter: UserNotificationCenterProtocol {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: options)
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }
}
