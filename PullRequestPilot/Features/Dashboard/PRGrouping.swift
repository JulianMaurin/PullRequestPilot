import Foundation

enum PRGrouping {

    struct PRStack: Identifiable {
        let root: PullRequest
        let children: [PullRequest]
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
        let headToPR = Dictionary(pullRequests.map { ($0.headRefName, $0) }, uniquingKeysWith: { first, _ in first })
        let byBase = Dictionary(grouping: pullRequests, by: { $0.baseRefName })
        let childIDs = Set(pullRequests.compactMap { pr -> String? in
            guard headToPR[pr.baseRefName] != nil else { return nil }
            return pr.id
        })
        let roots = pullRequests.filter { !childIDs.contains($0.id) }

        return roots.map { root in
            var children: [PullRequest] = []
            var currentHead = root.headRefName
            var visited: Set<String> = [root.id]
            let maxDepth = pullRequests.count
            while children.count < maxDepth,
                  let next = byBase[currentHead]?.first(where: { !visited.contains($0.id) }) {
                children.append(next)
                visited.insert(next.id)
                currentHead = next.headRefName
            }
            return PRStack(root: root, children: children)
        }
    }
}
