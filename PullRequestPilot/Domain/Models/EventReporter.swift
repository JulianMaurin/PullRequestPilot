import Foundation

/// Write-only view onto `EventCenter`. Layers that shouldn't be able to read
/// or dismiss events (stores, non-UI services) hold this instead of the full
/// center. Sendable so it can cross actor boundaries.
struct EventReporter: Sendable {
    typealias ErrorMatch = @Sendable (AppError) -> Bool

    private let _post: @Sendable (AppEvent) -> Void
    private let _resolve: @Sendable (@escaping ErrorMatch) -> Void

    init(post: @escaping @Sendable (AppEvent) -> Void, resolve: @escaping @Sendable (@escaping ErrorMatch) -> Void = { _ in }) {
        self._post = post
        self._resolve = resolve
    }

    func post(_ event: AppEvent) { _post(event) }
    func postError(_ error: AppError) { _post(.error(error)) }
    func postInfo(_ text: String) { _post(.info(text)) }
    func postWarning(_ text: String) { _post(.warning(text)) }

    /// The subsystem recovered: clears matching errors from every surface,
    /// including the standing banner.
    func resolve(matching match: @escaping ErrorMatch) { _resolve(match) }

    /// A no-op reporter — used in tests or contexts where no user surface exists.
    static let noop = EventReporter(post: { _ in })
}
