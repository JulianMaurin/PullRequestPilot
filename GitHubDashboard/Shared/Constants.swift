import Foundation

enum Constants {
    enum Keychain {
        static let githubToken = "github_personal_access_token"
    }

    enum App {
        static let refreshInterval: TimeInterval = 60
        static let maxPullRequests = 100
    }
}
