import Foundation

/// How long ago a pull request was opened. A creation date in the future
/// (server clock drift) reads as brand new in both styles.
enum PullRequestAge {
    /// "2 hr. ago", localized, for the list row.
    static func abbreviated(since createdAt: Date, relativeTo now: Date) -> String {
        guard createdAt <= now else { return "just now" }
        // Date.RelativeFormatStyle can't take a reference date before
        // macOS 15; a formatter per call shares no state between threads.
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: createdAt, relativeTo: now)
    }

    /// "2h", for the widgets' narrow badges.
    static func compact(since createdAt: Date, relativeTo now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(createdAt)) / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        if days < 30 { return "\(days)d" }
        return "\(days / 30)mo"
    }
}
