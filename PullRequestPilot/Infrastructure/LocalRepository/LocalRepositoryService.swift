import AppKit
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
    private var refreshTask: Task<Void, Never>?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "PullRequestPilot",
        category: "LocalRepository"
    )

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
        isScanning = true

        let entries = await Task.detached { [logger] in
            Self.buildIndex(directories: directories, logger: logger)
        }.value
        repoIndex = entries
        indexedRepoCount = entries.count
        lastScanDate = Date()
        isScanning = false
        logger.info("Scan complete: indexed \(entries.count) repo(s)")
    }

    func startPeriodicRefresh(directories: @escaping @Sendable () -> [URL], interval: TimeInterval = 120) {
        stopPeriodicRefresh()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                let dirs = directories()
                await self?.scan(directories: dirs)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stopPeriodicRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - Lookup (pure in-memory, no I/O)

    func findLocalDirectory(for pr: PullRequest) -> LocalRepoMatch? {
        let nameWithOwner = pr.repository.nameWithOwner.lowercased()
        let headRef = pr.headRefName
        let prSha = pr.headCommitSha

        let matchingRepos = repoIndex.filter { $0.nameWithOwner == nameWithOwner }

        for repo in matchingRepos {
            if repo.currentBranch == headRef {
                return LocalRepoMatch(path: repo.path, matchKind: .exactBranch)
            }

            for worktree in repo.worktrees {
                if worktree.branch == headRef {
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

    func openInVSCode(path: URL) {
        launchApp("Visual Studio Code", path: path)
    }

    func openInITerm(path: URL) {
        launchApp("iTerm", path: path)
    }

    private static let appBundleIDs: [String: String] = [
        "Visual Studio Code": "com.microsoft.VSCode",
        "iTerm": "com.googlecode.iterm2",
    ]

    private func launchApp(_ appName: String, path: URL) {
        guard let bundleID = Self.appBundleIDs[appName],
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            logger.error("Application not found: \(appName)")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([path], withApplicationAt: appURL, configuration: config) { [logger] _, error in
            if let error {
                logger.error("Failed to open \(appName): \(error)")
            }
        }
    }

    // MARK: - Index Building (runs off main thread)

    nonisolated private static func buildIndex(directories: [URL], logger: Logger) -> [RepoEntry] {
        var entries: [RepoEntry] = []

        for gitDir in directories {
            let repoDirs = discoverAllRepoDirs(in: gitDir)

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

                logger.debug("Indexed repo: \(nwo) at \(repoDir.path) (branch: \(branch ?? "detached"), worktrees: \(worktrees.count))")
            }
        }

        return entries
    }

    // MARK: - Discovery

    nonisolated private static func discoverAllRepoDirs(in directory: URL) -> [URL] {
        let fm = FileManager.default
        var repos: [URL] = []

        if isGitRepo(directory) {
            repos.append(directory)
        }

        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
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

    /// Parses `.git/config` to extract the remote "origin" URL, then derives `owner/repo`.
    nonisolated private static func extractNameWithOwner(repoDir: URL) -> String? {
        let configURL = repoDir.appendingPathComponent(".git/config")
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
        // SSH: git@github.com:owner/repo.git
        if url.contains("github.com:") {
            guard let afterColon = url.components(separatedBy: "github.com:").last else { return nil }
            return afterColon
                .replacingOccurrences(of: ".git", with: "")
                .lowercased()
        }

        // HTTPS: https://github.com/owner/repo.git
        if url.contains("github.com/") {
            guard let afterDomain = url.components(separatedBy: "github.com/").last else { return nil }
            return afterDomain
                .replacingOccurrences(of: ".git", with: "")
                .lowercased()
        }

        return nil
    }

    /// Reads `.git/HEAD` to get the current branch name.
    /// Returns `nil` for detached HEAD (raw SHA instead of symbolic ref).
    nonisolated private static func currentBranch(at repoDir: URL) -> String? {
        let headURL = repoDir.appendingPathComponent(".git/HEAD")
        guard let contents = try? String(contentsOf: headURL, encoding: .utf8) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)

        let prefix = "ref: refs/heads/"
        guard trimmed.hasPrefix(prefix) else { return nil }
        return String(trimmed.dropFirst(prefix.count))
    }

    /// Parses `.git/logs/HEAD` (the reflog) to extract recent commit SHAs.
    /// Each reflog line has format: `<old-sha> <new-sha> <author> <timestamp> <message>`
    nonisolated private static func recentCommitShas(at repoDir: URL, limit: Int = 100) -> Set<String> {
        let reflogURL = repoDir.appendingPathComponent(".git/logs/HEAD")
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

    /// Lists worktrees by reading `.git/worktrees/<name>/gitdir` and `HEAD`.
    nonisolated private static func listWorktrees(repoDir: URL) -> [WorktreeEntry] {
        let worktreesDir = repoDir.appendingPathComponent(".git/worktrees")
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
