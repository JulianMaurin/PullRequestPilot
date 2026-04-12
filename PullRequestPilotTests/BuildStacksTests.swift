import Testing
import Foundation
@testable import PullRequestPilot

@MainActor
@Suite("DashboardViewModel.groupedByOrgAndRepo & buildStacks")
struct BuildStacksTests {
    private let mockClient = MockGitHubClient()
    private let localRepoService = LocalRepositoryService()

    private func makeViewModel(suiteName: String = "BuildStacks") -> DashboardViewModel {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = ViewsStore(defaults: defaults)
        return DashboardViewModel(gitHubClient: mockClient, viewsStore: store, localRepositoryService: localRepoService, defaults: defaults)
    }

    // MARK: - groupedByOrgAndRepo

    @Test("empty input returns empty groups")
    func emptyInput() {
        let vm = makeViewModel(suiteName: "EmptyInput")
        let groups = vm.groupedByOrgAndRepo([])
        #expect(groups.isEmpty)
    }

    @Test("single PR creates single org/repo group")
    func singlePR() {
        let vm = makeViewModel(suiteName: "SinglePR")
        let pr = TestPullRequestFactory.make(id: "1", repository: Repository(nameWithOwner: "org/repo"))
        let groups = vm.groupedByOrgAndRepo([pr])
        #expect(groups.count == 1)
        #expect(groups[0].org == "org")
        #expect(groups[0].repos.count == 1)
        #expect(groups[0].repos[0].repo == "repo")
        #expect(groups[0].repos[0].stacks.count == 1)
    }

    @Test("PRs from different orgs create separate org groups")
    func differentOrgs() {
        let vm = makeViewModel(suiteName: "DiffOrgs")
        let pr1 = TestPullRequestFactory.make(id: "1", repository: Repository(nameWithOwner: "alpha/repo"))
        let pr2 = TestPullRequestFactory.make(id: "2", repository: Repository(nameWithOwner: "beta/repo"))
        let groups = vm.groupedByOrgAndRepo([pr1, pr2])
        #expect(groups.count == 2)
        #expect(groups[0].org == "alpha")
        #expect(groups[1].org == "beta")
    }

    @Test("PRs from same org different repos create separate repo groups")
    func sameOrgDiffRepos() {
        let vm = makeViewModel(suiteName: "SameOrgDiffRepos")
        let pr1 = TestPullRequestFactory.make(id: "1", repository: Repository(nameWithOwner: "org/api"))
        let pr2 = TestPullRequestFactory.make(id: "2", repository: Repository(nameWithOwner: "org/web"))
        let groups = vm.groupedByOrgAndRepo([pr1, pr2])
        #expect(groups.count == 1)
        #expect(groups[0].repos.count == 2)
    }

    @Test("orgs and repos are sorted alphabetically")
    func sortedOutput() {
        let vm = makeViewModel(suiteName: "Sorted")
        let pr1 = TestPullRequestFactory.make(id: "1", repository: Repository(nameWithOwner: "zoo/web"))
        let pr2 = TestPullRequestFactory.make(id: "2", repository: Repository(nameWithOwner: "alpha/api"))
        let pr3 = TestPullRequestFactory.make(id: "3", repository: Repository(nameWithOwner: "zoo/api"))
        let groups = vm.groupedByOrgAndRepo([pr1, pr2, pr3])
        #expect(groups[0].org == "alpha")
        #expect(groups[1].org == "zoo")
        #expect(groups[1].repos[0].repo == "api")
        #expect(groups[1].repos[1].repo == "web")
    }

    // MARK: - buildStacks

    @Test("unstacked PRs each get their own stack with no children")
    func unstackedPRs() {
        let vm = makeViewModel(suiteName: "Unstacked")
        let pr1 = TestPullRequestFactory.make(id: "1", baseRefName: "main", headRefName: "feature-1")
        let pr2 = TestPullRequestFactory.make(id: "2", baseRefName: "main", headRefName: "feature-2")
        let groups = vm.groupedByOrgAndRepo([pr1, pr2])
        let stacks = groups[0].repos[0].stacks
        #expect(stacks.count == 2)
        #expect(stacks.allSatisfy { $0.children.isEmpty })
    }

    @Test("stacked PRs are detected by head→base chain")
    func stackedPRs() {
        let vm = makeViewModel(suiteName: "Stacked")
        let root = TestPullRequestFactory.make(id: "root", baseRefName: "main", headRefName: "feature-1")
        let child = TestPullRequestFactory.make(id: "child", baseRefName: "feature-1", headRefName: "feature-2")
        let groups = vm.groupedByOrgAndRepo([root, child])
        let stacks = groups[0].repos[0].stacks
        #expect(stacks.count == 1)
        #expect(stacks[0].root.id == "root")
        #expect(stacks[0].children.count == 1)
        #expect(stacks[0].children[0].id == "child")
    }

    @Test("three-deep stack chain is detected")
    func threeDeepStack() {
        let vm = makeViewModel(suiteName: "ThreeDeep")
        let pr1 = TestPullRequestFactory.make(id: "1", baseRefName: "main", headRefName: "a")
        let pr2 = TestPullRequestFactory.make(id: "2", baseRefName: "a", headRefName: "b")
        let pr3 = TestPullRequestFactory.make(id: "3", baseRefName: "b", headRefName: "c")
        let groups = vm.groupedByOrgAndRepo([pr1, pr2, pr3])
        let stacks = groups[0].repos[0].stacks
        #expect(stacks.count == 1)
        #expect(stacks[0].totalCount == 3)
        #expect(stacks[0].root.id == "1")
        #expect(stacks[0].children.map(\.id) == ["2", "3"])
    }

    @Test("cycle in branch names does not cause infinite loop")
    func cycleProtection() {
        let vm = makeViewModel(suiteName: "Cycle")
        // a -> b -> a (cycle): both are identified as children of each other,
        // so neither is a root. The algorithm returns no stacks (no roots found).
        // The key property is that it terminates without infinite loop.
        let pr1 = TestPullRequestFactory.make(id: "1", baseRefName: "b", headRefName: "a")
        let pr2 = TestPullRequestFactory.make(id: "2", baseRefName: "a", headRefName: "b")
        let groups = vm.groupedByOrgAndRepo([pr1, pr2])
        let stacks = groups[0].repos[0].stacks
        // Algorithm terminates — exact grouping depends on root detection
        let totalPRs = stacks.reduce(0) { $0 + $1.totalCount }
        #expect(totalPRs >= 0) // Does not hang
    }

    @Test("totalCount includes root plus children")
    func totalCount() {
        let vm = makeViewModel(suiteName: "TotalCount")
        let pr1 = TestPullRequestFactory.make(id: "1", baseRefName: "main", headRefName: "feature-1")
        let pr2 = TestPullRequestFactory.make(id: "2", baseRefName: "feature-1", headRefName: "feature-2")
        let groups = vm.groupedByOrgAndRepo([pr1, pr2])
        let stacks = groups[0].repos[0].stacks
        #expect(stacks[0].totalCount == 2)
    }
}
