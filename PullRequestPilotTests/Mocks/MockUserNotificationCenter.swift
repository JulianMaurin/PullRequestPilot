import UserNotifications
@testable import PullRequestPilot

/// Plays back a configurable authorization state and records deliveries.
@MainActor
final class MockUserNotificationCenter: UserNotificationCenterProtocol {
    var status: UNAuthorizationStatus
    /// The status a permission request leaves behind (the user's answer).
    var statusAfterRequest: UNAuthorizationStatus
    private(set) var authorizationRequestCount = 0
    private(set) var delivered: [UNNotificationContent] = []

    init(status: UNAuthorizationStatus = .authorized, statusAfterRequest: UNAuthorizationStatus = .authorized) {
        self.status = status
        self.statusAfterRequest = statusAfterRequest
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        status
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        authorizationRequestCount += 1
        status = statusAfterRequest
        return status == .authorized
    }

    func add(_ request: UNNotificationRequest) async throws {
        delivered.append(request.content)
    }
}
