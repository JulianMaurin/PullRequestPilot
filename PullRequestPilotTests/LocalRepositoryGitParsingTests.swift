import Testing
import Foundation
@testable import PullRequestPilot

@MainActor
@Suite("LocalRepositoryService Git Parsing")
struct LocalRepositoryGitParsingTests {

    private let fm = FileManager.default

    /// Creates a temporary directory that is automatically cleaned up.
    private func makeTempDir() throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("PRPilotTest-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Creates a minimal fake git repo at the given path with an origin remote URL.
    private func createFakeRepo(
        at repoDir: URL,
        remoteURL: String,
        branch: String = "main",
        reflogEntries: [String] = []
    ) throws {
        let gitDir = repoDir.appendingPathComponent(".git")
        try fm.createDirectory(at: gitDir, withIntermediateDirectories: true)

        // Write config with origin remote
        let config = """
        [core]
            repositoryformatversion = 0
        [remote "origin"]
            url = \(remoteURL)
            fetch = +refs/heads/*:refs/remotes/origin/*
        """
        try config.write(to: gitDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        // Write HEAD with branch ref
        let head = "ref: refs/heads/\(branch)\n"
        try head.write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)

        // Write reflog
        if !reflogEntries.isEmpty {
            let logsDir = gitDir.appendingPathComponent("logs")
            try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
            let reflog = reflogEntries.joined(separator: "\n") + "\n"
            try reflog.write(to: logsDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        }
    }

    /// Creates a worktree entry inside a main repo's .git/worktrees directory.
    private func createFakeWorktree(
        mainRepoDir: URL,
        worktreeName: String,
        worktreePath: URL,
        branch: String? = nil
    ) throws {
        let gitDir = mainRepoDir.appendingPathComponent(".git")
        let worktreeDir = gitDir.appendingPathComponent("worktrees/\(worktreeName)")
        try fm.createDirectory(at: worktreeDir, withIntermediateDirectories: true)

        // gitdir file points to the worktree's .git file location
        let gitdirContent = worktreePath.appendingPathComponent(".git").path + "\n"
        try gitdirContent.write(to: worktreeDir.appendingPathComponent("gitdir"), atomically: true, encoding: .utf8)

        // HEAD for the worktree
        if let branch {
            try "ref: refs/heads/\(branch)\n".write(
                to: worktreeDir.appendingPathComponent("HEAD"),
                atomically: true, encoding: .utf8
            )
        } else {
            // Detached HEAD
            try "abc123def456abc123def456abc123def456abcd\n".write(
                to: worktreeDir.appendingPathComponent("HEAD"),
                atomically: true, encoding: .utf8
            )
        }

        // Create the worktree directory with a .git file (not directory) pointing back
        try fm.createDirectory(at: worktreePath, withIntermediateDirectories: true)
        let gitFileContent = "gitdir: \(worktreeDir.path)\n"
        try gitFileContent.write(to: worktreePath.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
    }

    // MARK: - Scan with real git repo structure

    @Test("scan indexes a repo with SSH remote URL")
    func scanSSHRepo() async throws {
        let tempDir = try makeTempDir()
        defer { try? fm.removeItem(at: tempDir) }

        let repoDir = tempDir.appendingPathComponent("my-repo")
        try createFakeRepo(at: repoDir, remoteURL: "git@github.com:owner/my-repo.git", branch: "feature-x")

        let service = LocalRepositoryService()
        await service.scan(directories: [tempDir])

        #expect(service.indexedRepoCount == 1)
        let entry = service.repoIndex.first
        #expect(entry?.nameWithOwner == "owner/my-repo")
        #expect(entry?.currentBranch == "feature-x")
    }

    @Test("scan indexes a repo with HTTPS remote URL")
    func scanHTTPSRepo() async throws {
        let tempDir = try makeTempDir()
        defer { try? fm.removeItem(at: tempDir) }

        let repoDir = tempDir.appendingPathComponent("my-repo")
        try createFakeRepo(at: repoDir, remoteURL: "https://github.com/org/project.git", branch: "main")

        let service = LocalRepositoryService()
        await service.scan(directories: [tempDir])

        #expect(service.indexedRepoCount == 1)
        #expect(service.repoIndex.first?.nameWithOwner == "org/project")
    }

    @Test("scan handles HTTPS URL without .git suffix")
    func scanHTTPSNoGitSuffix() async throws {
        let tempDir = try makeTempDir()
        defer { try? fm.removeItem(at: tempDir) }

        let repoDir = tempDir.appendingPathComponent("my-repo")
        try createFakeRepo(at: repoDir, remoteURL: "https://github.com/org/project", branch: "main")

        let service = LocalRepositoryService()
        await service.scan(directories: [tempDir])

        #expect(service.repoIndex.first?.nameWithOwner == "org/project")
    }

    @Test("scan skips directories without .git")
    func scanSkipsNonGitDirs() async throws {
        let tempDir = try makeTempDir()
        defer { try? fm.removeItem(at: tempDir) }

        // Create a regular directory (no .git)
        let plainDir = tempDir.appendingPathComponent("not-a-repo")
        try fm.createDirectory(at: plainDir, withIntermediateDirectories: true)

        let service = LocalRepositoryService()
        await service.scan(directories: [tempDir])

        #expect(service.indexedRepoCount == 0)
    }

    @Test("scan skips repos without origin remote")
    func scanSkipsNoOrigin() async throws {
        let tempDir = try makeTempDir()
        defer { try? fm.removeItem(at: tempDir) }

        let repoDir = tempDir.appendingPathComponent("local-only")
        let gitDir = repoDir.appendingPathComponent(".git")
        try fm.createDirectory(at: gitDir, withIntermediateDirectories: true)

        // Config with no origin remote
        let config = """
        [core]
            repositoryformatversion = 0
        """
        try config.write(to: gitDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/main\n".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)

        let service = LocalRepositoryService()
        await service.scan(directories: [tempDir])

        #expect(service.indexedRepoCount == 0)
    }

    @Test("scan skips repos with non-GitHub remote")
    func scanSkipsNonGitHubRemote() async throws {
        let tempDir = try makeTempDir()
        defer { try? fm.removeItem(at: tempDir) }

        let repoDir = tempDir.appendingPathComponent("gitlab-repo")
        try createFakeRepo(at: repoDir, remoteURL: "git@gitlab.com:org/repo.git")

        let service = LocalRepositoryService()
        await service.scan(directories: [tempDir])

        #expect(service.indexedRepoCount == 0)
    }

    // MARK: - Detached HEAD

    @Test("scan returns nil branch for detached HEAD")
    func scanDetachedHead() async throws {
        let tempDir = try makeTempDir()
        defer { try? fm.removeItem(at: tempDir) }

        let repoDir = tempDir.appendingPathComponent("detached-repo")
        let gitDir = repoDir.appendingPathComponent(".git")
        try fm.createDirectory(at: gitDir, withIntermediateDirectories: true)

        let config = """
        [remote "origin"]
            url = git@github.com:owner/repo.git
        """
        try config.write(to: gitDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        // Detached HEAD is a raw SHA, not a ref
        try "abc123def456abc123def456abc123def456abcd\n".write(
            to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8
        )

        let service = LocalRepositoryService()
        await service.scan(directories: [tempDir])

        #expect(service.indexedRepoCount == 1)
        #expect(service.repoIndex.first?.currentBranch == nil)
    }

    // MARK: - Reflog parsing

    @Test("scan extracts commit SHAs from reflog")
    func scanExtractsReflogShas() async throws {
        let tempDir = try makeTempDir()
        defer { try? fm.removeItem(at: tempDir) }

        let sha1 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let sha2 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let sha3 = "cccccccccccccccccccccccccccccccccccccccc"

        let repoDir = tempDir.appendingPathComponent("repo")
        try createFakeRepo(
            at: repoDir,
            remoteURL: "git@github.com:owner/repo.git",
            reflogEntries: [
                "0000000000000000000000000000000000000000 \(sha1) Author <a@b.com> 1700000000 +0000\tcommit (initial): init",
                "\(sha1) \(sha2) Author <a@b.com> 1700000100 +0000\tcommit: second",
                "\(sha2) \(sha3) Author <a@b.com> 1700000200 +0000\tcommit: third",
            ]
        )

        let service = LocalRepositoryService()
        await service.scan(directories: [tempDir])

        let shas = service.repoIndex.first?.commitShas ?? []
        #expect(shas.contains(sha1))
        #expect(shas.contains(sha2))
        #expect(shas.contains(sha3))
    }

    @Test("scan handles empty reflog gracefully")
    func scanEmptyReflog() async throws {
        let tempDir = try makeTempDir()
        defer { try? fm.removeItem(at: tempDir) }

        let repoDir = tempDir.appendingPathComponent("repo")
        try createFakeRepo(at: repoDir, remoteURL: "git@github.com:owner/repo.git", reflogEntries: [])

        let service = LocalRepositoryService()
        await service.scan(directories: [tempDir])

        #expect(service.repoIndex.first?.commitShas.isEmpty == true)
    }

    // MARK: - Worktree discovery

    @Test("scan discovers worktrees with branches")
    func scanDiscoverWorktrees() async throws {
        let tempDir = try makeTempDir()
        let worktreeDir = try makeTempDir() // separate directory so scan doesn't double-count
        defer {
            try? fm.removeItem(at: tempDir)
            try? fm.removeItem(at: worktreeDir)
        }

        let mainRepo = tempDir.appendingPathComponent("main-repo")
        try createFakeRepo(at: mainRepo, remoteURL: "git@github.com:owner/repo.git", branch: "main")

        let worktreePath = worktreeDir.appendingPathComponent("worktree-feature")
        try createFakeWorktree(mainRepoDir: mainRepo, worktreeName: "feature", worktreePath: worktreePath, branch: "feature-branch")

        let service = LocalRepositoryService()
        await service.scan(directories: [tempDir])

        #expect(service.indexedRepoCount == 1)
        let entry = service.repoIndex.first
        #expect(entry?.worktrees.count == 1)
        #expect(entry?.worktrees.first?.branch == "feature-branch")
    }

    @Test("a repository and its checked-out worktrees each list every worktree")
    func worktreeCheckoutsShareTheList() async throws {
        let tempDir = try makeTempDir()
        defer { try? fm.removeItem(at: tempDir) }
        let mainRepo = tempDir.appendingPathComponent("main-repo")
        try createFakeRepo(at: mainRepo, remoteURL: "git@github.com:owner/repo.git")
        try createFakeWorktree(mainRepoDir: mainRepo, worktreeName: "one", worktreePath: tempDir.appendingPathComponent("wt-one"), branch: "one")
        try createFakeWorktree(mainRepoDir: mainRepo, worktreeName: "two", worktreePath: tempDir.appendingPathComponent("wt-two"), branch: "two")

        let service = LocalRepositoryService()
        await service.scan(directories: [tempDir])

        #expect(service.repoIndex.count == 3)
        for entry in service.repoIndex {
            #expect(Set(entry.worktrees.compactMap(\.branch)) == ["one", "two"], "\(entry.path.lastPathComponent)")
        }
    }

    @Test("scan discovers worktrees with detached HEAD")
    func scanWorktreeDetachedHead() async throws {
        let tempDir = try makeTempDir()
        let worktreeDir = try makeTempDir()
        defer {
            try? fm.removeItem(at: tempDir)
            try? fm.removeItem(at: worktreeDir)
        }

        let mainRepo = tempDir.appendingPathComponent("main-repo")
        try createFakeRepo(at: mainRepo, remoteURL: "git@github.com:owner/repo.git")

        let worktreePath = worktreeDir.appendingPathComponent("worktree-detached")
        try createFakeWorktree(mainRepoDir: mainRepo, worktreeName: "detached", worktreePath: worktreePath, branch: nil)

        let service = LocalRepositoryService()
        await service.scan(directories: [tempDir])

        let entry = service.repoIndex.first
        #expect(entry?.worktrees.first?.branch == nil)
    }

    // MARK: - Discovery of repo in root directory

    @Test("scan discovers repo when the scanned directory itself is a git repo")
    func scanRootIsGitRepo() async throws {
        let tempDir = try makeTempDir()
        defer { try? fm.removeItem(at: tempDir) }

        // The scanned directory IS the git repo
        try createFakeRepo(at: tempDir, remoteURL: "git@github.com:owner/root-repo.git")

        let service = LocalRepositoryService()
        await service.scan(directories: [tempDir])

        #expect(service.indexedRepoCount == 1)
        #expect(service.repoIndex.first?.nameWithOwner == "owner/root-repo")
    }

    // MARK: - Multiple repos in one directory

    @Test("scan discovers multiple repos in a directory")
    func scanMultipleRepos() async throws {
        let tempDir = try makeTempDir()
        defer { try? fm.removeItem(at: tempDir) }

        try createFakeRepo(at: tempDir.appendingPathComponent("repo-a"), remoteURL: "git@github.com:org/repo-a.git")
        try createFakeRepo(at: tempDir.appendingPathComponent("repo-b"), remoteURL: "git@github.com:org/repo-b.git")

        let service = LocalRepositoryService()
        await service.scan(directories: [tempDir])

        #expect(service.indexedRepoCount == 2)
        let names = Set(service.repoIndex.map(\.nameWithOwner))
        #expect(names.contains("org/repo-a"))
        #expect(names.contains("org/repo-b"))
    }

    // MARK: - findLocalDirectory integration with scanned repos

    @Test("findLocalDirectory matches scanned repo by branch")
    func findLocalDirAfterScan() async throws {
        let tempDir = try makeTempDir()
        defer { try? fm.removeItem(at: tempDir) }

        try createFakeRepo(
            at: tempDir.appendingPathComponent("my-repo"),
            remoteURL: "git@github.com:owner/my-repo.git",
            branch: "feature-xyz"
        )

        let service = LocalRepositoryService()
        await service.scan(directories: [tempDir])

        let pr = try TestPullRequestFactory.make(
            repository: Repository(nameWithOwner: "owner/my-repo"),
            headRefName: "feature-xyz"
        )
        let match = service.findLocalDirectory(for: pr)
        #expect(match?.matchKind == .exactBranch)
    }

    @Test("a fork PR is not matched to a local checkout by branch name")
    func findLocalDirSkipsBranchMatchForForks() async throws {
        let tempDir = try makeTempDir()
        defer { try? fm.removeItem(at: tempDir) }

        let sha = "feedfacefeedfacefeedfacefeedfacefeedface"
        try createFakeRepo(
            at: tempDir.appendingPathComponent("repo"),
            remoteURL: "git@github.com:owner/repo.git",
            branch: "main",
            reflogEntries: [
                "0000000000000000000000000000000000000000 \(sha) Author <a@b.com> 1700000000 +0000\tcommit: fetched fork head"
            ]
        )

        let service = LocalRepositoryService()
        await service.scan(directories: [tempDir])

        let forkOnMain = try TestPullRequestFactory.make(
            repository: Repository(nameWithOwner: "owner/repo"),
            headRefName: "main",
            isCrossRepository: true
        )
        #expect(service.findLocalDirectory(for: forkOnMain) == nil)

        let fetchedFork = try TestPullRequestFactory.make(
            repository: Repository(nameWithOwner: "owner/repo"),
            headRefName: "main",
            headCommitSha: sha,
            isCrossRepository: true
        )
        #expect(service.findLocalDirectory(for: fetchedFork)?.matchKind == .commitMatch)
    }

    @Test("findLocalDirectory matches worktree branch after scan")
    func findLocalDirWorktreeAfterScan() async throws {
        let tempDir = try makeTempDir()
        let worktreeDir = try makeTempDir()
        defer {
            try? fm.removeItem(at: tempDir)
            try? fm.removeItem(at: worktreeDir)
        }

        let mainRepo = tempDir.appendingPathComponent("main-repo")
        try createFakeRepo(at: mainRepo, remoteURL: "git@github.com:owner/repo.git", branch: "main")

        let worktreePath = worktreeDir.appendingPathComponent("wt-feature")
        try createFakeWorktree(mainRepoDir: mainRepo, worktreeName: "feature", worktreePath: worktreePath, branch: "my-feature")

        let service = LocalRepositoryService()
        await service.scan(directories: [tempDir])

        let pr = try TestPullRequestFactory.make(
            repository: Repository(nameWithOwner: "owner/repo"),
            headRefName: "my-feature"
        )
        let match = service.findLocalDirectory(for: pr)
        #expect(match?.matchKind == .worktreeBranch)
    }

    @Test("findLocalDirectory matches by commit SHA in reflog")
    func findLocalDirByShaAfterScan() async throws {
        let tempDir = try makeTempDir()
        defer { try? fm.removeItem(at: tempDir) }

        let sha = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
        try createFakeRepo(
            at: tempDir.appendingPathComponent("repo"),
            remoteURL: "git@github.com:owner/repo.git",
            branch: "main",
            reflogEntries: [
                "0000000000000000000000000000000000000000 \(sha) Author <a@b.com> 1700000000 +0000\tcommit: something"
            ]
        )

        let service = LocalRepositoryService()
        await service.scan(directories: [tempDir])

        let pr = try TestPullRequestFactory.make(
            repository: Repository(nameWithOwner: "owner/repo"),
            headRefName: "other-branch",
            headCommitSha: sha
        )
        let match = service.findLocalDirectory(for: pr)
        #expect(match?.matchKind == .commitMatch)
    }

    // MARK: - Config parsing edge cases

    @Test("scan handles SSH URL with explicit port (ssh://)")
    func scanSSHWithExplicitPort() async throws {
        let tempDir = try makeTempDir()
        defer { try? fm.removeItem(at: tempDir) }

        let repoDir = tempDir.appendingPathComponent("port-repo")
        try createFakeRepo(at: repoDir, remoteURL: "ssh://git@github.com:22/owner/port-repo.git")

        let service = LocalRepositoryService()
        await service.scan(directories: [tempDir])

        #expect(service.indexedRepoCount == 1)
        #expect(service.repoIndex.first?.nameWithOwner == "owner/port-repo")
    }

    @Test("scan handles SSH URL with non-standard port")
    func scanSSHWithNonStandardPort() async throws {
        let tempDir = try makeTempDir()
        defer { try? fm.removeItem(at: tempDir) }

        let repoDir = tempDir.appendingPathComponent("custom-port-repo")
        try createFakeRepo(at: repoDir, remoteURL: "ssh://git@github.com:2222/owner/custom-port-repo.git")

        let service = LocalRepositoryService()
        await service.scan(directories: [tempDir])

        #expect(service.indexedRepoCount == 1)
        #expect(service.repoIndex.first?.nameWithOwner == "owner/custom-port-repo")
    }

    @Test("scan preserves interior .git in repo name for SCP-style remote")
    func scanSCPGitHubPagesRepo() async throws {
        let tempDir = try makeTempDir()
        defer { try? fm.removeItem(at: tempDir) }

        let repoDir = tempDir.appendingPathComponent("octocat.github.io")
        try createFakeRepo(at: repoDir, remoteURL: "git@github.com:octocat/octocat.github.io.git")

        let service = LocalRepositoryService()
        await service.scan(directories: [tempDir])

        #expect(service.repoIndex.first?.nameWithOwner == "octocat/octocat.github.io")
    }

    @Test("scan preserves interior .git in repo name for HTTPS remote")
    func scanHTTPSGitHubPagesRepo() async throws {
        let tempDir = try makeTempDir()
        defer { try? fm.removeItem(at: tempDir) }

        let repoDir = tempDir.appendingPathComponent("org.github.io")
        try createFakeRepo(at: repoDir, remoteURL: "https://github.com/org/org.github.io.git")

        let service = LocalRepositoryService()
        await service.scan(directories: [tempDir])

        #expect(service.repoIndex.first?.nameWithOwner == "org/org.github.io")
    }

    @Test("scan preserves interior .git in repo name for ssh:// remote")
    func scanSSHSchemeInteriorGitRepo() async throws {
        let tempDir = try makeTempDir()
        defer { try? fm.removeItem(at: tempDir) }

        let repoDir = tempDir.appendingPathComponent("my.gitops")
        try createFakeRepo(at: repoDir, remoteURL: "ssh://git@github.com/owner/my.gitops.git")

        let service = LocalRepositoryService()
        await service.scan(directories: [tempDir])

        #expect(service.repoIndex.first?.nameWithOwner == "owner/my.gitops")
    }

    @Test("scan preserves .github.io repo name without trailing .git suffix")
    func scanGitHubPagesRepoNoSuffix() async throws {
        let tempDir = try makeTempDir()
        defer { try? fm.removeItem(at: tempDir) }

        let repoDir = tempDir.appendingPathComponent("pages-repo")
        try createFakeRepo(at: repoDir, remoteURL: "https://github.com/org/org.github.io")

        let service = LocalRepositoryService()
        await service.scan(directories: [tempDir])

        #expect(service.repoIndex.first?.nameWithOwner == "org/org.github.io")
    }

    @Test("scan handles config with multiple remotes, picks origin")
    func scanMultipleRemotes() async throws {
        let tempDir = try makeTempDir()
        defer { try? fm.removeItem(at: tempDir) }

        let repoDir = tempDir.appendingPathComponent("multi-remote")
        let gitDir = repoDir.appendingPathComponent(".git")
        try fm.createDirectory(at: gitDir, withIntermediateDirectories: true)

        let config = """
        [remote "upstream"]
            url = git@github.com:upstream/repo.git
        [remote "origin"]
            url = git@github.com:fork/repo.git
        [branch "main"]
            remote = origin
        """
        try config.write(to: gitDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/main\n".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)

        let service = LocalRepositoryService()
        await service.scan(directories: [tempDir])

        #expect(service.repoIndex.first?.nameWithOwner == "fork/repo")
    }
}
