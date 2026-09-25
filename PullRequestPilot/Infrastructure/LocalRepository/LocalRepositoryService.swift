import Foundation
import os

struct LocalRepoMatch: Sendable {
    let path: URL
    let matchKind: MatchKind

    enum MatchKind: Sendable {
        case exactBranch
        case worktreeBranch
        case commitMatch
    }
}

@MainActor
@Observable
final class LocalRepositoryService {

    // MARK: - Properties

    private(set) var isScanning = false
    private(set) var lastScanDate: Date?
    private(set) var indexedRepoCount: Int = 0
    // internal setter for test injection via @testable import
    var repoIndex: [RepoEntry] = []
    /// Bumped every time a scan starts. Pending scans compare their captured
    /// generation before committing results — stale results are discarded.
    private var scanGeneration: UInt64 = 0
    /// Lock-backed so deinit can cancel without hopping to MainActor.
    private let refreshTaskStorage = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    private let activeScanTaskStorage = OSAllocatedUnfairLock<Task<[RepoEntry], Never>?>(initialState: nil)

    private let logger = Logger(category: "LocalRepository")

    deinit {
        refreshTaskStorage.withLock { task in
            task?.cancel()
            task = nil
        }
        activeScanTaskStorage.withLock { task in
            task?.cancel()
            task = nil
        }
    }

    // MARK: - Cache Model

    struct RepoEntry: Sendable {
        let path: URL
        let nameWithOwner: String
        let currentBranch: String?
        let commitShas: Set<String>
        let worktrees: [WorktreeEntry]
    }

    struct WorktreeEntry: Sendable {
        let path: URL
        let branch: String?
        let commitShas: Set<String>
    }

    // MARK: - Scanning

    func scan(directories: [URL]) async {
        activeScanTaskStorage.withLock { $0?.cancel() }
        scanGeneration &+= 1
        let capturedGeneration = scanGeneration
        isScanning = true

        let task = Task.detached { [logger] in
            Self.buildIndex(directories: directories, logger: logger)
        }
        activeScanTaskStorage.withLock { $0 = task }
        let entries = await task.value

        guard !Task.isCancelled, capturedGeneration == scanGeneration else {
            // A newer scan superseded us — do not overwrite its results.
            if capturedGeneration == scanGeneration {
                isScanning = false
            }
            return
        }
        repoIndex = entries
        indexedRepoCount = entries.count
        lastScanDate = Date()
        isScanning = false
        activeScanTaskStorage.withLock { $0 = nil }
        logger.info("Scan complete: indexed \(entries.count, privacy: .public) repo(s)")
    }

    func startPeriodicRefresh(directories: @MainActor @escaping @Sendable () -> [URL], interval: TimeInterval = 120) {
        stopPeriodicRefresh()
        let task = Task { [weak self] in
            while !Task.isCancelled {
                let dirs = directories()
                // Skip the filesystem walk entirely when no directories are
                // configured — saves sustained I/O on a menu-bar app that may
                // run for days with the window hidden.
                if !dirs.isEmpty {
                    await self?.scan(directories: dirs)
                }
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
            }
        }
        refreshTaskStorage.withLock { $0 = task }
    }

    func stopPeriodicRefresh() {
        refreshTaskStorage.withLock { task in
            task?.cancel()
            task = nil
        }
    }

    // MARK: - Lookup (pure in-memory, no I/O)

    func findLocalDirectory(for pr: PullRequest) -> LocalRepoMatch? {
        let nameWithOwner = pr.repository.nameWithOwner.lowercased()
        let headRef = pr.headRefName
        let prSha = pr.headCommitSha

        let matchingRepos = repoIndex.filter { $0.nameWithOwner == nameWithOwner }
        // A fork's branch name says nothing about the local clone's branch of
        // the same name, so fork PRs match by head commit only.
        let matchByBranch = !pr.isCrossRepository

        for repo in matchingRepos {
            if matchByBranch, repo.currentBranch == headRef {
                return LocalRepoMatch(path: repo.path, matchKind: .exactBranch)
            }

            for worktree in repo.worktrees {
                if matchByBranch, worktree.branch == headRef {
                    return LocalRepoMatch(path: worktree.path, matchKind: .worktreeBranch)
                }
            }

            if let sha = prSha {
                if repo.commitShas.contains(sha) {
                    return LocalRepoMatch(path: repo.path, matchKind: .commitMatch)
                }
                for worktree in repo.worktrees {
                    if worktree.commitShas.contains(sha) {
                        return LocalRepoMatch(path: worktree.path, matchKind: .commitMatch)
                    }
                }
            }
        }

        return nil
    }

    // MARK: - Index Building (runs off main thread)

    nonisolated private static func buildIndex(directories: [URL], logger: Logger) -> [RepoEntry] {
        var entries: [RepoEntry] = []

        for gitDir in directories {
            let repoDirs = discoverAllRepoDirs(in: gitDir, logger: logger)

            for repoDir in repoDirs {
                guard let nwo = extractNameWithOwner(repoDir: repoDir) else { continue }

                let branch = currentBranch(at: repoDir)
                let shas = recentCommitShas(at: repoDir)
                let worktrees = listWorktrees(repoDir: repoDir)

                entries.append(RepoEntry(
                    path: repoDir,
                    nameWithOwner: nwo,
                    currentBranch: branch,
                    commitShas: shas,
                    worktrees: worktrees
                ))

                logger.debug("Indexed repo: \(nwo, privacy: .private) at \(repoDir.path, privacy: .private) (branch: \(branch ?? "detached", privacy: .private), worktrees: \(worktrees.count, privacy: .public))")
            }
        }

        return entries
    }

    // MARK: - Discovery

    nonisolated private static func discoverAllRepoDirs(in directory: URL, logger: Logger) -> [URL] {
        let fm = FileManager.default
        var repos: [URL] = []

        if isGitRepo(directory) {
            repos.append(directory)
        }

        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            // Without this log, a sandbox/permission/stale-bookmark failure
            // here surfaces as a zero-repo scan with no diagnostic — masking
            // the root cause when users report "Open in VS Code stopped working".
            logger.error("Failed to enumerate \(directory.path, privacy: .private): \(error, privacy: .public)")
            return repos
        }

        for url in contents {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir && isGitRepo(url) {
                repos.append(url)
            }
        }

        return repos
    }

    nonisolated private static func isGitRepo(_ directory: URL) -> Bool {
        let gitPath = directory.appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: gitPath.path)
    }

    // MARK: - Git Operations (pure file reads, no Process)

    /// Resolves the actual `.git` directory for a repo or worktree.
    /// In a normal repo, `.git` is a directory — we return it directly.
    /// In a worktree, `.git` is a file containing `gitdir: /path/to/main/.git/worktrees/<name>`.
    /// Returns `nil` if neither form exists.
    nonisolated private static func resolveGitDir(for repoDir: URL) -> URL? {
        let gitPath = repoDir.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitPath.path, isDirectory: &isDir) else { return nil }

        if isDir.boolValue {
            return gitPath
        }

        // .git is a file — parse "gitdir: <path>"
        guard let contents = try? String(contentsOf: gitPath, encoding: .utf8) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let gitdirPrefix = "gitdir: "
        guard trimmed.hasPrefix(gitdirPrefix) else { return nil }
        let rawPath = String(trimmed.dropFirst(gitdirPrefix.count))

        // Path may be relative or absolute
        if rawPath.hasPrefix("/") {
            return URL(fileURLWithPath: rawPath)
        }
        return repoDir.appendingPathComponent(rawPath).standardized
    }

    /// For a worktree's git dir (e.g. `/repo/.git/worktrees/foo`), resolves the main repo's `.git` directory.
    /// Returns the input unchanged if it doesn't look like a worktree subdirectory.
    nonisolated private static func resolveMainGitDir(from gitDir: URL) -> URL {
        // Worktree git dirs live at <main>/.git/worktrees/<name>
        let parent = gitDir.deletingLastPathComponent()
        if parent.lastPathComponent == "worktrees" {
            return parent.deletingLastPathComponent()
        }
        return gitDir
    }

    /// Parses `.git/config` to extract the remote "origin" URL, then derives `owner/repo`.
    nonisolated private static func extractNameWithOwner(repoDir: URL) -> String? {
        guard let gitDir = resolveGitDir(for: repoDir) else { return nil }
        let mainGitDir = resolveMainGitDir(from: gitDir)
        let configURL = mainGitDir.appendingPathComponent("config")
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }

        var inOriginRemote = false
        for line in contents.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("[remote \"origin\"]") {
                inOriginRemote = true
                continue
            }

            if trimmed.hasPrefix("[") {
                inOriginRemote = false
                continue
            }

            if inOriginRemote && trimmed.hasPrefix("url = ") {
                let url = String(trimmed.dropFirst("url = ".count))
                return parseNameWithOwner(from: url)
            }
        }

        return nil
    }

    nonisolated private static func parseNameWithOwner(from url: String) -> String? {
        // SSH with URL scheme: ssh://git@github.com/owner/repo.git
        // or ssh://git@github.com:22/owner/repo.git (with port)
        if url.hasPrefix("ssh://"), url.contains("github.com") {
            guard let afterDomain = url.components(separatedBy: "github.com").last else { return nil }
            // Strip optional :port prefix (e.g. ":22/owner/repo" → "/owner/repo")
            let pathPart: String
            if afterDomain.hasPrefix(":") {
                guard let slashIndex = afterDomain.firstIndex(of: "/") else { return nil }
                pathPart = String(afterDomain[slashIndex...])
            } else {
                pathPart = afterDomain
            }
            let trimmed = strippingGitSuffix(
                pathPart.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            )
            return trimmed.isEmpty ? nil : trimmed.lowercased()
        }

        // SCP-style SSH: git@github.com:owner/repo.git
        if url.contains("github.com:") && !url.hasPrefix("ssh://") {
            guard let afterColon = url.components(separatedBy: "github.com:").last else { return nil }
            return strippingGitSuffix(afterColon).lowercased()
        }

        // HTTPS: https://github.com/owner/repo.git
        if url.contains("github.com/") {
            guard let afterDomain = url.components(separatedBy: "github.com/").last else { return nil }
            return strippingGitSuffix(afterDomain).lowercased()
        }

        return nil
    }

    /// Removes only a trailing `.git` clone suffix. A substring replace would
    /// mangle repo names containing `.git` (e.g. `octocat/octocat.github.io`),
    /// breaking the index match against the PR's `nameWithOwner`.
    nonisolated private static func strippingGitSuffix(_ name: String) -> String {
        name.hasSuffix(".git") ? String(name.dropLast(".git".count)) : name
    }

    /// Reads `HEAD` to get the current branch name.
    /// Returns `nil` for detached HEAD (raw SHA instead of symbolic ref).
    nonisolated private static func currentBranch(at repoDir: URL) -> String? {
        guard let gitDir = resolveGitDir(for: repoDir) else { return nil }
        let headURL = gitDir.appendingPathComponent("HEAD")
        guard let contents = try? String(contentsOf: headURL, encoding: .utf8) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)

        let prefix = "ref: refs/heads/"
        guard trimmed.hasPrefix(prefix) else { return nil }
        return String(trimmed.dropFirst(prefix.count))
    }

    /// Parses the reflog to extract recent commit SHAs.
    /// Each reflog line has format: `<old-sha> <new-sha> <author> <timestamp> <message>`
    nonisolated private static func recentCommitShas(at repoDir: URL, limit: Int = 100) -> Set<String> {
        guard let gitDir = resolveGitDir(for: repoDir) else { return [] }
        let reflogURL = gitDir.appendingPathComponent("logs/HEAD")
        guard let contents = try? String(contentsOf: reflogURL, encoding: .utf8) else { return [] }

        var shas = Set<String>()
        let lines = contents.components(separatedBy: "\n")

        // Walk from the end (most recent) to collect up to `limit` unique SHAs
        for line in lines.reversed() {
            guard shas.count < limit else { break }
            let parts = line.split(separator: " ", maxSplits: 2)
            guard parts.count >= 2 else { continue }
            // new-sha is the second field — the state after the operation
            let sha = String(parts[1])
            if sha.count == 40, sha.allSatisfy(\.isHexDigit) {
                shas.insert(sha)
            }
        }

        return shas
    }

    /// Lists worktrees by reading `worktrees/<name>/gitdir` and `HEAD` inside the git directory.
    nonisolated private static func listWorktrees(repoDir: URL) -> [WorktreeEntry] {
        guard let gitDir = resolveGitDir(for: repoDir) else { return [] }
        let mainGitDir = resolveMainGitDir(from: gitDir)
        let worktreesDir = mainGitDir.appendingPathComponent("worktrees")
        let fm = FileManager.default

        guard let entries = try? fm.contentsOfDirectory(
            at: worktreesDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var result: [WorktreeEntry] = []

        for entry in entries {
            // The gitdir file contains the path to the worktree's working directory
            let gitdirURL = entry.appendingPathComponent("gitdir")
            guard let gitdirContents = try? String(contentsOf: gitdirURL, encoding: .utf8) else { continue }
            let worktreePath = URL(fileURLWithPath: gitdirContents.trimmingCharacters(in: .whitespacesAndNewlines))
                .deletingLastPathComponent()

            // Read HEAD for the branch
            let headURL = entry.appendingPathComponent("HEAD")
            var branch: String?
            if let headContents = try? String(contentsOf: headURL, encoding: .utf8) {
                let trimmed = headContents.trimmingCharacters(in: .whitespacesAndNewlines)
                let refPrefix = "ref: refs/heads/"
                if trimmed.hasPrefix(refPrefix) {
                    branch = String(trimmed.dropFirst(refPrefix.count))
                }
            }

            let shas = recentCommitShas(at: worktreePath)

            result.append(WorktreeEntry(
                path: worktreePath,
                branch: branch,
                commitShas: shas
            ))
        }

        return result
    }
}
