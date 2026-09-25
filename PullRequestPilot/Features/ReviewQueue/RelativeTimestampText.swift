import SwiftUI

/// A leaf `Text` view that re-renders every 30 seconds to keep a relative
/// timestamp (e.g. "3 minutes ago") fresh.
///
/// Wrapping only the leaf `Text` in `TimelineView(.periodic)` — rather than the
/// entire list — avoids cascading SwiftUI diff + layout work across every row
/// on every tick.
///
/// Usage:
/// ```swift
/// RelativeTimestampText(date: pr.createdAt) { date, now in
///     pr.age(relativeTo: now)
/// }
/// ```
///
/// The `date` parameter is passed back into `formatter` purely as a convenience
/// for formatters that key off a stored event date. Callers are free to ignore
/// it and close over their own state (e.g. the enclosing `PullRequest`).
struct RelativeTimestampText: View {
    let date: Date
    let formatter: (_ date: Date, _ now: Date) -> String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(formatter(date, context.date))
        }
    }
}
