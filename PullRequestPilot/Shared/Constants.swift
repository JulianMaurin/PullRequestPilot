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
        // swiftlint:disable:next force_unwrapping
        static let privacyPolicy = URL(string: "https://julianmaurin.github.io/PullRequestPilot/privacy")!
        // swiftlint:disable:next force_unwrapping
        static let support = URL(string: "https://github.com/JulianMaurin/PullRequestPilot/issues")!
    }

    enum Notifications {
        static let prRefreshIntervalChanged = Notification.Name("prRefreshIntervalChanged")
    }
}
