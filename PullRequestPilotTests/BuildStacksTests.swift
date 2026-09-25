import Testing
import Foundation
@testable import PullRequestPilot

@MainActor
@Suite("PRGrouping.groupedByOrgAndRepo & buildStacks")
struct BuildStacksTests {
    // MARK: - groupedByOrgAndRepo

    @Test("empty input returns empty groups")
    func emptyInput() throws {
        let groups = PRGrouping.groupedByOrgAndRepo([])
        #expect(groups.isEmpty)
    }

    @Test("single PR creates single org/repo group")
    func singlePR() throws {
        let pr = try TestPullRequestFactory.make(id: "1", repository: Repository(nameWithOwner: "org/repo"))
        let groups = PRGrouping.groupedByOrgAndRepo([pr])
        #expect(groups.count == 1)
        #expect(groups[0].org == "org")
        #expect(groups[0].repos.count == 1)
        #expect(groups[0].repos[0].repo == "repo")
        #expect(groups[0].repos[0].stacks.count == 1)
    }

    @Test("PRs from different orgs create separate org groups")
    func differentOrgs() throws {
        let pr1 = try TestPullRequestFactory.make(id: "1", repository: Repository(nameWithOwner: "alpha/repo"))
        let pr2 = try TestPullRequestFactory.make(id: "2", repository: Repository(nameWithOwner: "beta/repo"))
        let groups = PRGrouping.groupedByOrgAndRepo([pr1, pr2])
        #expect(groups.count == 2)
        #expect(groups[0].org == "alpha")
        #expect(groups[1].org == "beta")
    }

    @Test("PRs from same org different repos create separate repo groups")
    func sameOrgDiffRepos() throws {
        let pr1 = try TestPullRequestFactory.make(id: "1", repository: Repository(nameWithOwner: "org/api"))
        let pr2 = try TestPullRequestFactory.make(id: "2", repository: Repository(nameWithOwner: "org/web"))
        let groups = PRGrouping.groupedByOrgAndRepo([pr1, pr2])
        #expect(groups.count == 1)
        #expect(groups[0].repos.count == 2)
    }

    @Test("orgs and repos are sorted alphabetically")
    func sortedOutput() throws {
        let pr1 = try TestPullRequestFactory.make(id: "1", repository: Repository(nameWithOwner: "zoo/web"))
        let pr2 = try TestPullRequestFactory.make(id: "2", repository: Repository(nameWithOwner: "alpha/api"))
        let pr3 = try TestPullRequestFactory.make(id: "3", repository: Repository(nameWithOwner: "zoo/api"))
        let groups = PRGrouping.groupedByOrgAndRepo([pr1, pr2, pr3])
        #expect(groups[0].org == "alpha")
        #expect(groups[1].org == "zoo")
        #expect(groups[1].repos[0].repo == "api")
        #expect(groups[1].repos[1].repo == "web")
    }

    // MARK: - buildStacks

    @Test("unstacked PRs each get their own stack with no children")
    func unstackedPRs() throws {
        let pr1 = try TestPullRequestFactory.make(id: "1", baseRefName: "main", headRefName: "feature-1")
        let pr2 = try TestPullRequestFactory.make(id: "2", baseRefName: "main", headRefName: "feature-2")
        let groups = PRGrouping.groupedByOrgAndRepo([pr1, pr2])
        let stacks = groups[0].repos[0].stacks
        #expect(stacks.count == 2)
        #expect(stacks.allSatisfy { $0.children.isEmpty })
    }

    @Test("stacked PRs are detected by head→base chain")
    func stackedPRs() throws {
        let root = try TestPullRequestFactory.make(id: "root", baseRefName: "main", headRefName: "feature-1")
        let child = try TestPullRequestFactory.make(id: "child", baseRefName: "feature-1", headRefName: "feature-2")
        let groups = PRGrouping.groupedByOrgAndRepo([root, child])
        let stacks = groups[0].repos[0].stacks
        #expect(stacks.count == 1)
        #expect(stacks[0].root.id == "root")
        #expect(stacks[0].children.count == 1)
        #expect(stacks[0].children[0].id == "child")
    }

    @Test("three-deep stack chain is detected")
    func threeDeepStack() throws {
        let pr1 = try TestPullRequestFactory.make(id: "1", baseRefName: "main", headRefName: "a")
        let pr2 = try TestPullRequestFactory.make(id: "2", baseRefName: "a", headRefName: "b")
        let pr3 = try TestPullRequestFactory.make(id: "3", baseRefName: "b", headRefName: "c")
        let groups = PRGrouping.groupedByOrgAndRepo([pr1, pr2, pr3])
        let stacks = groups[0].repos[0].stacks
        #expect(stacks.count == 1)
        #expect(stacks[0].totalCount == 3)
        #expect(stacks[0].root.id == "1")
        #expect(stacks[0].children.map(\.id) == ["2", "3"])
    }

    @Test("two-PR cycle emits both PRs as standalone stacks")
    func cycleProtection() throws {
        // a -> b -> a (cycle): each PR's base matches the other's head,
        // so both are classified as children and neither qualifies as a root.
        // Cycle members must still be emitted, not silently dropped.
        let pr1 = try TestPullRequestFactory.make(id: "1", baseRefName: "b", headRefName: "a")
        let pr2 = try TestPullRequestFactory.make(id: "2", baseRefName: "a", headRefName: "b")
        let groups = PRGrouping.groupedByOrgAndRepo([pr1, pr2])
        let stacks = groups[0].repos[0].stacks
        #expect(stacks.count == 2)
        #expect(stacks.reduce(0) { $0 + $1.totalCount } == 2)
        #expect(Set(stacks.map(\.root.id)) == ["1", "2"])
        #expect(stacks.allSatisfy { $0.children.isEmpty })
    }

    @Test("three-PR cycle emits all PRs as standalone stacks")
    func threePRCycle() throws {
        // a -> b -> c -> a: every PR's base matches another's head, so
        // no root exists and all three fall through to the standalone pass.
        let pr1 = try TestPullRequestFactory.make(id: "1", baseRefName: "c", headRefName: "a")
        let pr2 = try TestPullRequestFactory.make(id: "2", baseRefName: "a", headRefName: "b")
        let pr3 = try TestPullRequestFactory.make(id: "3", baseRefName: "b", headRefName: "c")
        let groups = PRGrouping.groupedByOrgAndRepo([pr1, pr2, pr3])
        let stacks = groups[0].repos[0].stacks
        #expect(stacks.count == 3)
        #expect(stacks.reduce(0) { $0 + $1.totalCount } == 3)
        #expect(Set(stacks.map(\.root.id)) == ["1", "2", "3"])
        #expect(stacks.allSatisfy { $0.children.isEmpty })
    }

    @Test("cycle alongside a normal stack loses no PRs")
    func cycleAlongsideNormalStack() throws {
        let root = try TestPullRequestFactory.make(id: "root", baseRefName: "main", headRefName: "feat")
        let child = try TestPullRequestFactory.make(id: "child", baseRefName: "feat", headRefName: "feat-2")
        let cycleA = try TestPullRequestFactory.make(id: "cycleA", baseRefName: "develop", headRefName: "release")
        let cycleB = try TestPullRequestFactory.make(id: "cycleB", baseRefName: "release", headRefName: "develop")
        let groups = PRGrouping.groupedByOrgAndRepo([root, child, cycleA, cycleB])
        let stacks = groups[0].repos[0].stacks
        #expect(stacks.reduce(0) { $0 + $1.totalCount } == 4)
        #expect(stacks.count == 3)
        let rootStack = stacks.first { $0.root.id == "root" }
        #expect(rootStack?.children.map(\.id) == ["child"])
        #expect(Set(stacks.map(\.root.id)) == ["root", "cycleA", "cycleB"])
    }

    @Test("partial cycle with root terminates due to max depth guard")
    func partialCycleWithRoot() throws {
        // root → a → b, but b also points back to a via baseRefName.
        // The root is valid (base=main), but children a→b could loop
        // if not for the visited set. Verify it terminates correctly.
        let root = try TestPullRequestFactory.make(id: "root", baseRefName: "main", headRefName: "a")
        let childA = try TestPullRequestFactory.make(id: "childA", baseRefName: "a", headRefName: "b")
        let childB = try TestPullRequestFactory.make(id: "childB", baseRefName: "b", headRefName: "a")
        let groups = PRGrouping.groupedByOrgAndRepo([root, childA, childB])
        let stacks = groups[0].repos[0].stacks
        // root is the only non-child (base=main, not anyone's head)
        // childA and childB both have bases matching someone's head
        #expect(stacks.count == 1)
        #expect(stacks[0].root.id == "root")
        // children count should be exactly 2 (a, b) — visited set prevents revisiting
        #expect(stacks[0].children.count == 2)
    }

    @Test("every PR stacked on the same branch is nested, not just the first")
    func siblingsAreNested() throws {
        let root = try TestPullRequestFactory.make(id: "root", baseRefName: "main", headRefName: "a")
        let first = try TestPullRequestFactory.make(id: "first", baseRefName: "a", headRefName: "b")
        let second = try TestPullRequestFactory.make(id: "second", baseRefName: "a", headRefName: "c")
        let stacks = PRGrouping.groupedByOrgAndRepo([root, first, second])[0].repos[0].stacks

        #expect(stacks.count == 1)
        #expect(stacks[0].totalCount == 3)
        #expect(stacks[0].children.map(\.id) == ["first", "second"])
        #expect(stacks[0].children.map(\.depth) == [1, 1])
    }

    @Test("members are listed depth-first with their depth")
    func depthFirstOrder() throws {
        let root = try TestPullRequestFactory.make(id: "root", baseRefName: "main", headRefName: "a")
        let first = try TestPullRequestFactory.make(id: "first", baseRefName: "a", headRefName: "b")
        let second = try TestPullRequestFactory.make(id: "second", baseRefName: "a", headRefName: "c")
        let firstChild = try TestPullRequestFactory.make(id: "firstChild", baseRefName: "b", headRefName: "d")
        let stacks = PRGrouping.groupedByOrgAndRepo([root, first, second, firstChild])[0].repos[0].stacks

        #expect(stacks[0].children.map(\.id) == ["first", "firstChild", "second"])
        #expect(stacks[0].children.map(\.depth) == [1, 2, 1])
    }

    @Test("two roots with the same head branch share a child once")
    func duplicateHeadsCountOnce() throws {
        let closed = try TestPullRequestFactory.make(id: "closed", state: .closed, baseRefName: "main", headRefName: "x")
        let reopened = try TestPullRequestFactory.make(id: "reopened", baseRefName: "main", headRefName: "x")
        let child = try TestPullRequestFactory.make(id: "child", baseRefName: "x", headRefName: "y")
        let stacks = PRGrouping.groupedByOrgAndRepo([closed, reopened, child])[0].repos[0].stacks

        #expect(stacks.reduce(0) { $0 + $1.totalCount } == 3)
        #expect(stacks.flatMap(\.children).map(\.id) == ["child"])
    }

    @Test("a fork's branch name doesn't stack a same-repository PR on it")
    func forkHeadsAreNotParents() throws {
        let fork = try TestPullRequestFactory.make(id: "fork", baseRefName: "main", headRefName: "feature", isCrossRepository: true)
        let local = try TestPullRequestFactory.make(id: "local", baseRefName: "feature", headRefName: "follow-up")
        let stacks = PRGrouping.groupedByOrgAndRepo([fork, local])[0].repos[0].stacks

        #expect(stacks.count == 2)
        #expect(stacks.allSatisfy { $0.children.isEmpty })
    }

    @Test("totalCount includes root plus children")
    func totalCount() throws {
        let pr1 = try TestPullRequestFactory.make(id: "1", baseRefName: "main", headRefName: "feature-1")
        let pr2 = try TestPullRequestFactory.make(id: "2", baseRefName: "feature-1", headRefName: "feature-2")
        let groups = PRGrouping.groupedByOrgAndRepo([pr1, pr2])
        let stacks = groups[0].repos[0].stacks
        #expect(stacks[0].totalCount == 2)
    }
}
