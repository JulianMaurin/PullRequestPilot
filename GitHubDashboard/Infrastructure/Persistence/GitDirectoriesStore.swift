import Foundation

final class GitDirectoriesStore: @unchecked Sendable {
    private static let key = "git_directories"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [URL] {
        guard let paths = defaults.stringArray(forKey: Self.key) else {
            return []
        }
        return paths.map { URL(fileURLWithPath: $0) }
    }

    func save(_ directories: [URL]) {
        let paths = directories.map(\.path)
        defaults.set(paths, forKey: Self.key)
    }
}
