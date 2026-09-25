import Testing
import Foundation
@testable import PullRequestPilot

@MainActor
@Suite("LocalRepositoryService")
struct LocalRepositoryServiceTests {

    private func makeService(repos: [LocalRepositoryService.RepoEntry] = []) -> LocalRepositoryService {
        let service = LocalRepositoryService()
        service.repoIndex = repos
        return service
    }

    private func makeRepoEntry(
        path: String = "/repos/owner/repo",
        nameWithOwner: String = "owner/repo",
        currentBranch: String? = "main",
        commitShas: Set<String> = [],
        worktrees: [LocalRepositoryService.WorktreeEntry] = []
    ) -> LocalRepositoryService.RepoEntry {
        LocalRepositoryService.RepoEntry(
            path: URL(fileURLWithPath: path),
            nameWithOwner: nameWithOwner,
            currentBranch: currentBranch,
            commitShas: commitShas,
            worktrees: worktrees
        )
    }

    private func makeWorktreeEntry(
        path: String,
        branch: String?,
        commitShas: Set<String> = []
    ) -> LocalRepositoryService.WorktreeEntry {
        LocalRepositoryService.WorktreeEntry(
            path: URL(fileURLWithPath: path),
            branch: branch,
            commitShas: commitShas
        )
    }

    // MARK: - findLocalDirectory: Strategy 1 — Exact branch match

    @Test("finds repo by exact branch match in main working tree")
    func findByExactBranch() throws {
        let service = makeService(repos: [
            makeRepoEntry(path: "/repos/my-repo", nameWithOwner: "owner/repo", currentBranch: "feature-x"),
        ])

        let pr = try TestPullRequestFactory.make(
            repository: Repository(nameWithOwner: "owner/repo"),
            headRefName: "feature-x"
        )
        let match = service.findLocalDirectory(for: pr)
        #expect(match != nil)
        #expect(match?.matchKind == .exactBranch)
        #expect(match?.path.path == "/repos/my-repo")
    }

    @Test("returns nil when branch doesn't match")
    func noMatchWhenBranchDiffers() throws {
        let service = makeService(repos: [
            makeRepoEntry(path: "/repos/repo", nameWithOwner: "owner/repo", currentBranch: "main"),
        ])

        let pr = try TestPullRequestFactory.make(
            repository: Repository(nameWithOwner: "owner/repo"),
            headRefName: "feature-y",
            headCommitSha: nil
        )
        #expect(service.findLocalDirectory(for: pr) == nil)
    }

    @Test("returns nil when repo name doesn't match")
    func noMatchWhenRepoDiffers() throws {
        let service = makeService(repos: [
            makeRepoEntry(nameWithOwner: "owner/other-repo", currentBranch: "main"),
        ])

        let pr = try TestPullRequestFactory.make(
            repository: Repository(nameWithOwner: "owner/repo"),
            headRefName: "main"
        )
        #expect(service.findLocalDirectory(for: pr) == nil)
    }

    // MARK: - findLocalDirectory: Strategy 2 — Worktree branch match

    @Test("finds repo by worktree branch match")
    func findByWorktreeBranch() throws {
        let wt = makeWorktreeEntry(path: "/repos/repo-wt/feature-z", branch: "feature-z")
        let service = makeService(repos: [
            makeRepoEntry(
                path: "/repos/repo",
                nameWithOwner: "owner/repo",
                currentBranch: "main",
                worktrees: [wt]
            ),
        ])

        let pr = try TestPullRequestFactory.make(
            repository: Repository(nameWithOwner: "owner/repo"),
            headRefName: "feature-z"
        )
        let match = service.findLocalDirectory(for: pr)
        #expect(match != nil)
        #expect(match?.matchKind == .worktreeBranch)
        #expect(match?.path.path == "/repos/repo-wt/feature-z")
    }

    @Test("exact branch takes priority over worktree")
    func exactBranchPriority() throws {
        let wt = makeWorktreeEntry(path: "/repos/repo-wt/main", branch: "main")
        let service = makeService(repos: [
            makeRepoEntry(
                path: "/repos/repo",
                nameWithOwner: "owner/repo",
                currentBranch: "main",
                worktrees: [wt]
            ),
        ])

        let pr = try TestPullRequestFactory.make(
            repository: Repository(nameWithOwner: "owner/repo"),
            headRefName: "main"
        )
        let match = service.findLocalDirectory(for: pr)
        #expect(match?.matchKind == .exactBranch)
        #expect(match?.path.path == "/repos/repo")
    }

    // MARK: - findLocalDirectory: Strategy 3 — Commit SHA match

    @Test("finds repo by commit SHA in main working tree")
    func findByCommitShaMainTree() throws {
        let service = makeService(repos: [
            makeRepoEntry(
                path: "/repos/repo",
                nameWithOwner: "owner/repo",
                currentBranch: "different-branch",
                commitShas: ["abc123", "def456"]
            ),
        ])

        let pr = try TestPullRequestFactory.make(
            repository: Repository(nameWithOwner: "owner/repo"),
            headRefName: "stacked-branch",
            headCommitSha: "abc123"
        )
        let match = service.findLocalDirectory(for: pr)
        #expect(match != nil)
        #expect(match?.matchKind == .commitMatch)
        #expect(match?.path.path == "/repos/repo")
    }

    @Test("finds repo by commit SHA in worktree")
    func findByCommitShaWorktree() throws {
        let wt = makeWorktreeEntry(
            path: "/repos/repo-wt/stack",
            branch: "stack-base",
            commitShas: ["sha999"]
        )
        let service = makeService(repos: [
            makeRepoEntry(
                path: "/repos/repo",
                nameWithOwner: "owner/repo",
                currentBranch: "main",
                commitShas: [],
                worktrees: [wt]
            ),
        ])

        let pr = try TestPullRequestFactory.make(
            repository: Repository(nameWithOwner: "owner/repo"),
            headRefName: "stack-pr-2",
            headCommitSha: "sha999"
        )
        let match = service.findLocalDirectory(for: pr)
        #expect(match != nil)
        #expect(match?.matchKind == .commitMatch)
        #expect(match?.path.path == "/repos/repo-wt/stack")
    }

    @Test("SHA match is skipped when headCommitSha is nil")
    func noShaMatchWhenNil() throws {
        let service = makeService(repos: [
            makeRepoEntry(
                nameWithOwner: "owner/repo",
                currentBranch: "different",
                commitShas: ["abc123"]
            ),
        ])

        let pr = try TestPullRequestFactory.make(
            repository: Repository(nameWithOwner: "owner/repo"),
            headRefName: "other-branch",
            headCommitSha: nil
        )
        #expect(service.findLocalDirectory(for: pr) == nil)
    }

    // MARK: - Case insensitivity

    @Test("nameWithOwner matching is case-insensitive")
    func caseInsensitiveMatch() throws {
        let service = makeService(repos: [
            makeRepoEntry(nameWithOwner: "owner/myrepo", currentBranch: "main"),
        ])

        let pr = try TestPullRequestFactory.make(
            repository: Repository(nameWithOwner: "Owner/MyRepo"),
            headRefName: "main"
        )
        #expect(service.findLocalDirectory(for: pr) != nil)
    }

    // MARK: - Multiple repos

    @Test("matches correct repo among multiple")
    func multipleRepos() throws {
        let service = makeService(repos: [
            makeRepoEntry(path: "/repos/repo-a", nameWithOwner: "org/repo-a", currentBranch: "main"),
            makeRepoEntry(path: "/repos/repo-b", nameWithOwner: "org/repo-b", currentBranch: "feature"),
        ])

        let pr = try TestPullRequestFactory.make(
            repository: Repository(nameWithOwner: "org/repo-b"),
            headRefName: "feature"
        )
        let match = service.findLocalDirectory(for: pr)
        #expect(match?.path.path == "/repos/repo-b")
    }

    // MARK: - Empty index

    @Test("returns nil when index is empty")
    func emptyIndex() throws {
        let service = makeService(repos: [])
        let pr = try TestPullRequestFactory.make()
        #expect(service.findLocalDirectory(for: pr) == nil)
    }

    // MARK: - Scan

    @Test("scan with empty directories results in zero indexed repos")
    func scanEmptyDirectories() async {
        let service = LocalRepositoryService()
        await service.scan(directories: [])
        #expect(service.indexedRepoCount == 0)
        #expect(service.lastScanDate != nil)
        #expect(!service.isScanning)
    }

    @Test("scan with nonexistent directory doesn't crash")
    func scanNonexistentDirectory() async {
        let service = LocalRepositoryService()
        await service.scan(directories: [URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")])
        #expect(service.indexedRepoCount == 0)
    }

    // MARK: - Periodic Refresh

    /// Counts how often a periodic refresh asked for its directories: once
    /// per tick.
    @MainActor
    private final class TickCounter {
        var count = 0
    }

    @Test("startPeriodicRefresh ticks right away and then on every interval")
    func startPeriodicRefreshTicks() async throws {
        let service = LocalRepositoryService()
        let ticks = TickCounter()
        service.startPeriodicRefresh(directories: { ticks.count += 1; return [] }, interval: 0.05)
        defer { service.stopPeriodicRefresh() }

        try await TestWait.until { ticks.count >= 2 }
        #expect(ticks.count >= 2)
    }

    @Test("stopPeriodicRefresh ends the loop")
    func stopPeriodicRefresh() async throws {
        let service = LocalRepositoryService()
        let ticks = TickCounter()
        service.startPeriodicRefresh(directories: { ticks.count += 1; return [] }, interval: 0.05)
        try await TestWait.until { ticks.count >= 1 }

        service.stopPeriodicRefresh()
        let ticksAtStop = ticks.count
        // Six intervals: a live loop would tick again well within them.
        try await TestWait.until(timeout: .milliseconds(300)) { ticks.count > ticksAtStop }

        #expect(ticks.count == ticksAtStop)
    }

    @Test("startPeriodicRefresh replaces the running loop")
    func startPeriodicRefreshReplacesExisting() async throws {
        let service = LocalRepositoryService()
        let first = TickCounter()
        let second = TickCounter()
        service.startPeriodicRefresh(directories: { first.count += 1; return [] }, interval: 0.05)
        try await TestWait.until { first.count >= 1 }

        service.startPeriodicRefresh(directories: { second.count += 1; return [] }, interval: 0.05)
        defer { service.stopPeriodicRefresh() }
        let firstAtReplace = first.count
        try await TestWait.until { second.count >= 3 }

        #expect(second.count >= 3)
        #expect(first.count == firstAtReplace)
    }

    // MARK: - Multiple worktrees

    @Test("checks all worktrees for branch match")
    func multipleWorktrees() throws {
        let wt1 = makeWorktreeEntry(path: "/repos/wt1", branch: "feature-a")
        let wt2 = makeWorktreeEntry(path: "/repos/wt2", branch: "feature-b")
        let service = makeService(repos: [
            makeRepoEntry(
                nameWithOwner: "owner/repo",
                currentBranch: "main",
                worktrees: [wt1, wt2]
            ),
        ])

        let pr = try TestPullRequestFactory.make(
            repository: Repository(nameWithOwner: "owner/repo"),
            headRefName: "feature-b"
        )
        let match = service.findLocalDirectory(for: pr)
        #expect(match?.matchKind == .worktreeBranch)
        #expect(match?.path.path == "/repos/wt2")
    }
}
