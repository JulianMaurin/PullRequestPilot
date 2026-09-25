import Foundation

enum PRGrouping {

    struct PRStack: Identifiable {
        struct Member: Identifiable {
            let pullRequest: PullRequest
            /// 1 for a PR based on the root's branch, 2 for one based on that
            /// PR's branch, and so on.
            let depth: Int
            var id: String { pullRequest.id }
        }

        let root: PullRequest
        /// Every PR stacked on `root`, depth-first: each member is followed by
        /// the PRs stacked on it, then by its siblings.
        let children: [Member]
        var id: String { root.id }
        var totalCount: Int { 1 + children.count }
    }

    struct OrgGroup {
        let org: String
        let repos: [RepoGroup]
    }

    struct RepoGroup {
        let repo: String
        let stacks: [PRStack]
    }

    static func groupedByOrgAndRepo(_ pullRequests: [PullRequest]) -> [OrgGroup] {
        let byOrg = Dictionary(grouping: pullRequests) { $0.repository.owner }
        return byOrg.keys.sorted().compactMap { org in
            guard let orgPRs = byOrg[org] else { return nil }
            let byRepo = Dictionary(grouping: orgPRs) { $0.repository.name }
            let repoGroups = byRepo.keys.sorted().compactMap { repo -> RepoGroup? in
                guard let repoPRs = byRepo[repo] else { return nil }
                return RepoGroup(repo: repo, stacks: buildStacks(repoPRs))
            }
            return OrgGroup(org: org, repos: repoGroups)
        }
    }

    static func buildStacks(_ pullRequests: [PullRequest]) -> [PRStack] {
        // A fork's branch lives in another repository, so its name says
        // nothing about this repository's branches: only same-repository
        // heads can be another PR's base.
        let stackableHeads = Set(pullRequests.filter { !$0.isCrossRepository }.map(\.headRefName))
        let byBase = Dictionary(grouping: pullRequests, by: \.baseRefName)
        let roots = pullRequests.filter { !stackableHeads.contains($0.baseRefName) }

        // Shared across every walk, so a PR reachable from two parents (two
        // PRs with the same head branch) is listed and counted once.
        var emittedIDs: Set<String> = []

        func members(stackedOn parent: PullRequest, depth: Int) -> [PRStack.Member] {
            guard !parent.isCrossRepository else { return [] }
            var result: [PRStack.Member] = []
            for child in byBase[parent.headRefName] ?? [] where !emittedIDs.contains(child.id) {
                emittedIDs.insert(child.id)
                result.append(PRStack.Member(pullRequest: child, depth: depth))
                result += members(stackedOn: child, depth: depth + 1)
            }
            return result
        }

        var stacks: [PRStack] = []
        for root in roots where !emittedIDs.contains(root.id) {
            emittedIDs.insert(root.id)
            stacks.append(PRStack(root: root, children: members(stackedOn: root, depth: 1)))
        }

        // Base/head cycles (e.g. release PR + back-merge PR referencing each
        // other's branches) classify every member as a child, so no root walk
        // reaches them; emit them as standalone stacks instead of dropping them.
        for pr in pullRequests where !emittedIDs.contains(pr.id) {
            emittedIDs.insert(pr.id)
            stacks.append(PRStack(root: pr, children: []))
        }
        return stacks
    }
}
