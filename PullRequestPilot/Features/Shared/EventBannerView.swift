import SwiftUI

/// Inline banner for standing errors (`AppError.isStanding`). Each screen
/// passes a filter for the errors it has no other surface for.
struct EventBannerView: View {
    struct Action {
        let label: String
        let run: () -> Void

        /// Shows a corruption backup in Finder; the file lives in the app's
        /// own container, so the sandbox allows it.
        static func revealBackup(atPath path: String) -> Action {
            Action(label: "Reveal Backup") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
    }

    let events: EventCenter
    let filter: (AppError) -> Bool
    var actionFor: ((AppError) -> Action?)?

    init(events: EventCenter, filter: @escaping (AppError) -> Bool, actionFor: ((AppError) -> Action?)? = nil) {
        self.events = events
        self.filter = filter
        self.actionFor = actionFor
    }

    private var match: (event: AppEvent, error: AppError)? {
        // standingEvents, not activeEvents: the banner is the persistent
        // surface — it must survive the toast's auto-dismiss and clear only
        // on explicit dismissal or subsystem recovery.
        for event in events.standingEvents {
            guard case .error(let err) = event.payload, filter(err) else { continue }
            return (event, err)
        }
        return nil
    }

    var body: some View {
        if let match {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(match.event.message)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let action = actionFor?(match.error) {
                    Button(action.label, action: action.run)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
                Button {
                    events.dismiss(match.event.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss banner")
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.orange.opacity(0.12))
            )
        }
    }
}
