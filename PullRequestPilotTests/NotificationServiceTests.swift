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
        let service = NotificationService(defaults: defaults, center: MockUserNotificationCenter(), reporter: center.reporter())
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

@Suite("NotificationService authorization and delivery")
@MainActor
struct NotificationServiceAuthorizationTests {

    private func makeService(center: MockUserNotificationCenter, recorder: EventRecorder = EventRecorder()) throws -> (NotificationService, UserDefaults) {
        let suiteName = "NotificationServiceAuthorizationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (NotificationService(defaults: defaults, center: center, reporter: recorder.reporter()), defaults)
    }

    @Test("checking authorization while notifications are denied keeps every bell")
    func deniedAuthorizationKeepsBells() async throws {
        let center = MockUserNotificationCenter(status: .denied)
        let (service, defaults) = try makeService(center: center)
        let first = UUID()
        let second = UUID()
        service.setEnabled(for: first, enabled: true)
        service.setEnabled(for: second, enabled: true)

        await service.refreshAuthorization()

        #expect(service.systemDenied)
        #expect(service.isEnabled(for: first))
        #expect(service.isEnabled(for: second))
        #expect(Set(defaults.stringArray(forKey: Constants.UserDefaultsKeys.notifiedViewIDs) ?? []) == [first.uuidString, second.uuidString])

        center.status = .authorized
        await service.refreshAuthorization()
        #expect(!service.systemDenied)
        #expect(service.isEnabled(for: first))
    }

    @Test("turning a bell on while denied keeps it on and explains why")
    func bellWhileDeniedExplains() async throws {
        let center = MockUserNotificationCenter(status: .denied)
        let recorder = EventRecorder()
        let (service, _) = try makeService(center: center, recorder: recorder)
        let viewID = UUID()

        service.setEnabled(for: viewID, enabled: true)
        await service.ensurePermission()

        #expect(service.isEnabled(for: viewID))
        #expect(center.authorizationRequestCount == 0)
        #expect(recorder.events.map(\.payload) == [.warning(NotificationService.deniedExplanation)])
    }

    @Test("the first bell asks for permission; declining keeps the bell and explains")
    func firstBellRequestsPermission() async throws {
        let center = MockUserNotificationCenter(status: .notDetermined, statusAfterRequest: .denied)
        let recorder = EventRecorder()
        let (service, _) = try makeService(center: center, recorder: recorder)
        let viewID = UUID()

        service.setEnabled(for: viewID, enabled: true)
        await service.ensurePermission()

        #expect(center.authorizationRequestCount == 1)
        #expect(service.isEnabled(for: viewID))
        #expect(service.systemDenied)
        #expect(recorder.events.map(\.payload) == [.warning(NotificationService.deniedExplanation)])
    }

    @Test("granting permission posts nothing")
    func grantedPermissionIsQuiet() async throws {
        let center = MockUserNotificationCenter(status: .notDetermined, statusAfterRequest: .authorized)
        let recorder = EventRecorder()
        let (service, _) = try makeService(center: center, recorder: recorder)

        await service.ensurePermission()

        #expect(service.systemAuthorized)
        #expect(recorder.events.isEmpty)
    }

    @Test("a notification groups under its view and leads to the pull request it announced")
    func deliveredNotificationRoutesToPullRequest() async throws {
        let center = MockUserNotificationCenter(status: .authorized)
        let (service, _) = try makeService(center: center)
        let viewID = UUID()
        let pr = try TestPullRequestFactory.make(id: "PR_7")

        await service.deliver(viewTitle: "View", viewID: viewID, addedPRs: [pr])

        let content = try #require(center.delivered.first)
        #expect(content.threadIdentifier == viewID.uuidString)
        #expect(NotificationRoute(userInfo: content.userInfo) == NotificationRoute(viewID: viewID, pullRequestID: "PR_7"))
    }

    @Test("a notification for several pull requests leads to their view")
    func deliveredNotificationRoutesToView() async throws {
        let center = MockUserNotificationCenter(status: .authorized)
        let (service, _) = try makeService(center: center)
        let viewID = UUID()
        let prs = [try TestPullRequestFactory.make(id: "PR_1"), try TestPullRequestFactory.make(id: "PR_2")]

        await service.deliver(viewTitle: "View", viewID: viewID, addedPRs: prs)

        let content = try #require(center.delivered.first)
        #expect(NotificationRoute(userInfo: content.userInfo) == NotificationRoute(viewID: viewID))
    }

    @Test("userInfo without a view ID routes nowhere")
    func malformedRoute() {
        #expect(NotificationRoute(userInfo: [:]) == nil)
        #expect(NotificationRoute(userInfo: ["viewID": "not-a-uuid"]) == nil)
    }

    @Test("nothing is delivered while notifications are denied")
    func deliverSkipsWhenDenied() async throws {
        let center = MockUserNotificationCenter(status: .denied)
        let (service, _) = try makeService(center: center)
        let pr = try TestPullRequestFactory.make()

        await service.deliver(viewTitle: "View", viewID: UUID(), addedPRs: [pr])

        #expect(center.delivered.isEmpty)
    }
}
