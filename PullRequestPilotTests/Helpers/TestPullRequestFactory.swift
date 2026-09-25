import Foundation
@testable import PullRequestPilot

enum TestPullRequestFactory {
    static func make(
        id: String = "PR_1",
        number: Int = 1,
        title: String = "Test PR",
        url: URL = URL(string: "https://github.com/owner/repo/pull/1")!,
        repository: Repository = Repository(nameWithOwner: "owner/repo"),
        author: Author = Author(login: "author", avatarURL: nil),
        createdAt: Date = Date().addingTimeInterval(-3600),
        updatedAt: Date = Date(),
        additions: Int = 10,
        deletions: Int = 5,
        state: PullRequestState = .open,
        isDraft: Bool = false,
        checkStatus: CheckStatus? = .success,
        reviewDecision: ReviewDecision? = .reviewRequired,
        totalThreads: Int = 0,
        unresolvedThreads: Int = 0,
        labels: [Label] = [],
        baseRefName: String = "main",
        headRefName: String = "feature-1",
        headCommitSha: String? = nil,
        isCrossRepository: Bool = false,
        lastActivity: LastActivity? = nil,
        latestReviews: [UserReview] = []
    ) -> PullRequest {
        PullRequest(
            id: id,
            number: number,
            title: title,
            url: url,
            repository: repository,
            author: author,
            createdAt: createdAt,
            updatedAt: updatedAt,
            additions: additions,
            deletions: deletions,
            state: state,
            isDraft: isDraft,
            checkStatus: checkStatus,
            reviewDecision: reviewDecision,
            totalThreads: totalThreads,
            unresolvedThreads: unresolvedThreads,
            labels: labels,
            baseRefName: baseRefName,
            headRefName: headRefName,
            headCommitSha: headCommitSha,
            isCrossRepository: isCrossRepository,
            lastActivity: lastActivity,
            latestReviews: latestReviews
        )
    }
}
