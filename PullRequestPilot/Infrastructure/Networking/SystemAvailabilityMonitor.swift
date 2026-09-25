import AppKit
import Foundation
import Network

enum SystemAvailabilityEvent: Sendable, Equatable {
    /// The system or the displays went to sleep: nobody is looking, and a
    /// sleeping Mac can't fetch.
    case sleepStarted
    case sleepEnded
    case networkReachabilityChanged(isReachable: Bool)
}

/// Reports sleep/wake and network reachability so polling can pause while
/// nothing useful can be fetched and resume the moment it can.
final class SystemAvailabilityMonitor {
    /// Single consumer: the auto-refresh scheduler.
    let events: AsyncStream<SystemAvailabilityEvent>

    private let continuation: AsyncStream<SystemAvailabilityEvent>.Continuation
    private let workspaceNotificationCenter: NotificationCenter
    private let observerTokens: [NSObjectProtocol]
    private let pathMonitor = NWPathMonitor()

    init(workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        let (events, continuation) = AsyncStream.makeStream(
            of: SystemAvailabilityEvent.self,
            bufferingPolicy: .bufferingNewest(8)
        )
        self.events = events
        self.continuation = continuation
        self.workspaceNotificationCenter = workspaceNotificationCenter

        let transitions: [(Notification.Name, SystemAvailabilityEvent)] = [
            (NSWorkspace.willSleepNotification, .sleepStarted),
            (NSWorkspace.screensDidSleepNotification, .sleepStarted),
            (NSWorkspace.didWakeNotification, .sleepEnded),
            (NSWorkspace.screensDidWakeNotification, .sleepEnded),
        ]
        observerTokens = transitions.map { name, event in
            workspaceNotificationCenter.addObserver(forName: name, object: nil, queue: nil) { _ in
                continuation.yield(event)
            }
        }

        pathMonitor.pathUpdateHandler = { path in
            continuation.yield(.networkReachabilityChanged(isReachable: path.status == .satisfied))
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.pullrequestpilot.network-path"))
    }

    deinit {
        observerTokens.forEach(workspaceNotificationCenter.removeObserver)
        pathMonitor.cancel()
        continuation.finish()
    }
}
