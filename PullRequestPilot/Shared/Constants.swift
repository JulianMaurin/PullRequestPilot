import Foundation

enum Constants {
    enum Keychain {
        static let githubToken = "github_personal_access_token"
    }

    enum App {
        static let defaultPRRefreshInterval: TimeInterval = 60
        static let defaultRepoScanInterval: TimeInterval = 120
        static let maxPullRequests = 100
        static let appGroupIdentifier = WidgetData.appGroupIdentifier
    }

    enum UserDefaultsKeys {
        static let prRefreshInterval = "prRefreshInterval"
        static let repoScanInterval = "repoScanInterval"
        static let notifiedViewIDs = "notifiedViewIDs"
        static let selectedViewID = "selectedViewID"
        static let collapsedOrgs = "collapsedOrgs"
        static let collapsedRepos = "collapsedRepos"
        static let badgeViewIDs = "badgeViewIDs"
    }

    enum URLs {
        static let privacyPolicy: URL = {
            guard let url = URL(string: "https://julianmaurin.github.io/PullRequestPilot/privacy") else {
                preconditionFailure("Invalid static URL: privacyPolicy")
            }
            return url
        }()
        static let support: URL = {
            guard let url = URL(string: "https://github.com/JulianMaurin/PullRequestPilot/issues") else {
                preconditionFailure("Invalid static URL: support")
            }
            return url
        }()
    }

    enum Notifications {
        static let prRefreshIntervalChanged = Notification.Name("prRefreshIntervalChanged")
    }
}
