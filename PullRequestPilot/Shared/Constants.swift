import Foundation

enum Constants {
    enum Keychain {
        static let githubToken = "github_personal_access_token"
    }

    enum App {
        static let defaultPRRefreshInterval: TimeInterval = 60
        static let defaultRepoScanInterval: TimeInterval = 120
        static let maxPullRequests = 100
        /// Search results per page; GitHub allows at most 100.
        static let searchPageSize = 50
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
        static let privacyPolicy: URL =
            URL(string: "https://julianmaurin.github.io/PullRequestPilot/privacy")
            ?? URL(fileURLWithPath: "/")
        static let support: URL =
            URL(string: "https://github.com/JulianMaurin/PullRequestPilot/issues")
            ?? URL(fileURLWithPath: "/")
        /// GitHub's classic-token form, pre-filled with the repo scope.
        static let newClassicToken: URL =
            URL(string: "https://github.com/settings/tokens/new?scopes=repo&description=Pull%20Request%20Pilot")
            ?? URL(fileURLWithPath: "/")
    }

    enum Notifications {
        static let prRefreshIntervalChanged = Notification.Name("prRefreshIntervalChanged")
    }
}
