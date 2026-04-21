import SwiftUI

// MARK: - ToastOverlay

/// Renders the top-most 3 active events as a stack of toasts anchored to the
/// top of the window. Reads `EventCenter.activeEvents` directly so it updates
/// whenever `post(_:)` or `dismiss(_:)` is called.
struct ToastOverlay: View {
    let events: EventCenter

    private var visible: [AppEvent] {
        Array(events.activeEvents.prefix(3))
    }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(visible) { event in
                ToastBanner(
                    event: event,
                    onDismiss: { events.dismiss(event.id) },
                    onHoverChange: { hovering in
                        if hovering {
                            events.pauseAutoDismiss(event.id)
                        } else {
                            events.resumeAutoDismiss(event.id)
                        }
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .opacity
                ))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .animation(.easeInOut(duration: 0.2), value: visible.map(\.id))
        .frame(maxWidth: .infinity, alignment: .top)
        .allowsHitTesting(!visible.isEmpty)
    }
}

// MARK: - ToastBanner

private struct ToastBanner: View {
    let event: AppEvent
    let onDismiss: () -> Void
    let onHoverChange: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
            Text(event.message)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss notification")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(tint.opacity(0.4), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 2)
        )
        .onHover(perform: onHoverChange)
    }

    private var iconName: String {
        switch event.level {
        case .error: return "exclamationmark.triangle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private var tint: Color {
        switch event.level {
        case .error: return .red
        case .warning: return .orange
        case .info: return .accentColor
        }
    }
}
