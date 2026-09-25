import Foundation

/// The color a status icon is drawn in. Views map every case, so a new one
/// can't silently fall back to a default.
enum StatusTint: Sendable {
    case green
    case red
    case purple
    case blue
    case yellow
    case gray
    /// The surrounding text's secondary color.
    case secondary
}
