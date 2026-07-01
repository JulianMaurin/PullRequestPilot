import Testing
import Foundation
import UserNotifications
@testable import PullRequestPilot

@Suite("NotificationService.handlePermissionError")
@MainActor
struct NotificationServiceTests {

    private func makeService() throws -> (NotificationService, EventCenter) {
        let suiteName = "NotificationServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let center = EventCenter()
        let service = NotificationService(defaults: defaults, reporter: center.reporter())
        return (service, center)
    }

    @Test("notificationsNotAllowed is treated as denied and does not post a toast")
    func notificationsNotAllowedSuppressesToast() async throws {
        let (service, center) = try makeService()
        let error = NSError(
            domain: UNErrorDomain,
            code: UNError.Code.notificationsNotAllowed.rawValue,
            userInfo: nil
        )

        let granted = service.handlePermissionError(error as Error)
        #expect(granted == false)

        // Give the reporter's Task { @MainActor } hop a chance to run.
        for _ in 0..<20 { await Task.yield() }
        #expect(center.events.isEmpty, "notificationsNotAllowed must not surface as a user-visible error")
    }

    @Test("CancellationError is treated as denied and does not post a toast")
    func cancellationSuppressesToast() async throws {
        let (service, center) = try makeService()

        let granted = service.handlePermissionError(CancellationError())
        #expect(granted == false)

        for _ in 0..<20 { await Task.yield() }
        #expect(center.events.isEmpty)
    }

    @Test("other errors post a notificationSystemError toast")
    func otherErrorsPostToast() async throws {
        let (service, center) = try makeService()
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }

        let granted = service.handlePermissionError(Boom())
        #expect(granted == false)

        for _ in 0..<20 where center.events.isEmpty { await Task.yield() }
        guard case .error(let err) = center.events.first?.payload,
              case .notificationSystemError(let detail) = err
        else {
            Issue.record("Expected notificationSystemError, got \(String(describing: center.events.first))")
            return
        }
        #expect(detail == "boom")
    }
}
