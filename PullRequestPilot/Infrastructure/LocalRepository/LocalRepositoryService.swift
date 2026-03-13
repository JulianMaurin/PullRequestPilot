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
    private(set) var gitAvailable: Bool = true
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

        let gitExists = await Task.detached {
            Self.isGitInstalled()
        }.value
        gitAvailable = gitExists

        guard gitExists else {
            repoIndex = []
            indexedRepoCount = 0
            lastScanDate = Date()
            isScanning = false
            logger.warning("git not found at /usr/bin/git — install Xcode Command Line Tools to enable local repo scanning")
            return
        }

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
        var fallback: LocalRepoMatch?

        for repo in matchingRepos {
            // Strategy 1: Exact branch match in main working tree
            if repo.currentBranch == headRef {
                return LocalRepoMatch(path: repo.path, matchKind: .exactBranch)
            }

            // Strategy 2: Check worktrees for exact branch match
            for worktree in repo.worktrees {
                if worktree.branch == headRef {
                    return LocalRepoMatch(path: worktree.path, matchKind: .worktreeBranch)
                }
            }

            // Strategy 3: Match by commit SHA in recent history
            // Handles stack tools where the PR branch name differs from local branch.
            // Each branch/worktree caches its recent commit SHAs so this is a set lookup.
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

    // MARK: - Git Operations

    nonisolated private static func extractNameWithOwner(repoDir: URL) -> String? {
        guard let output = runGit(["remote", "get-url", "origin"], at: repoDir) else { return nil }
        let url = output.trimmingCharacters(in: .whitespacesAndNewlines)

        // SSH: git@github.com:owner/repo.git
        if url.contains("github.com:") {
            let afterColon = url.components(separatedBy: "github.com:").last ?? ""
            return afterColon
                .replacingOccurrences(of: ".git", with: "")
                .lowercased()
        }

        // HTTPS: https://github.com/owner/repo.git
        if url.contains("github.com/") {
            let afterDomain = url.components(separatedBy: "github.com/").last ?? ""
            return afterDomain
                .replacingOccurrences(of: ".git", with: "")
                .lowercased()
        }

        return nil
    }

    nonisolated private static func currentBranch(at repoDir: URL) -> String? {
        runGit(["rev-parse", "--abbrev-ref", "HEAD"], at: repoDir)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func recentCommitShas(at repoDir: URL, limit: Int = 100) -> Set<String> {
        guard let output = runGit(["log", "--format=%H", "-n", "\(limit)"], at: repoDir) else {
            return []
        }
        return Set(
            output.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
    }

    nonisolated private static func listWorktrees(repoDir: URL) -> [WorktreeEntry] {
        guard let output = runGit(["worktree", "list", "--porcelain"], at: repoDir) else {
            return []
        }

        var worktreePaths: [(path: URL, branch: String?)] = []
        var currentPath: URL?
        var currentBranch: String?

        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("worktree ") {
                if let path = currentPath {
                    worktreePaths.append((path: path, branch: currentBranch))
                }
                let pathStr = String(line.dropFirst("worktree ".count))
                currentPath = URL(fileURLWithPath: pathStr)
                currentBranch = nil
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                currentBranch = ref.replacingOccurrences(of: "refs/heads/", with: "")
            }
        }

        if let path = currentPath {
            worktreePaths.append((path: path, branch: currentBranch))
        }

        // Exclude the main worktree, then collect recent commits for each
        return worktreePaths
            .filter { $0.path != repoDir }
            .map { entry in
                WorktreeEntry(
                    path: entry.path,
                    branch: entry.branch,
                    commitShas: recentCommitShas(at: entry.path)
                )
            }
    }

    // MARK: - Shell

    nonisolated private static func isGitInstalled() -> Bool {
        let url = URL(fileURLWithPath: "/usr/bin/git")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return false }
        let process = Process()
        process.executableURL = url
        process.arguments = ["--version"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    nonisolated private static func runGit(_ args: [String], at directory: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = directory

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
