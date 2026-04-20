import SwiftUI

/// Inline banner scoped to a particular kind of error. Views that want to
/// surface a persistent failure (e.g., hide-reviewed disabled because the
/// viewer identity is unavailable) render this and pass a filter predicate.
struct EventBannerView: View {
    let events: EventCenter
    let filter: (AppError) -> Bool

    private var match: AppEvent? {
        events.activeEvents.first(where: { event in
            guard case .error(let err) = event.payload else { return false }
            return filter(err)
        })
    }

    var body: some View {
        if let event = match {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(event.message)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    events.dismiss(event.id)
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
