import Foundation

/// The `pullrequestpilot://` links the app answers; the widgets build them.
enum DeepLink {
    static let scheme = "pullrequestpilot"
    static let viewHost = "view"

    /// `pullrequestpilot://view/<viewID>`: opens the app on that view.
    static func viewURL(viewID: String) -> URL? {
        URL(string: "\(scheme)://\(viewHost)/\(viewID)")
    }
}
