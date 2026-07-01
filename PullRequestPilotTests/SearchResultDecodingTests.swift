import Testing
import Foundation
@testable import PullRequestPilot

@Suite("SearchResult custom decoding")
struct SearchResultDecodingTests {

    @Test("decodes valid PullRequest nodes")
    func decodesValidPRNodes() throws {
        let json = """
        {
            "nodes": [
                {
                    "id": "PR_1",
                    "number": 42,
                    "title": "Fix bug",
                    "url": "https://github.com/owner/repo/pull/42",
                    "createdAt": "2024-01-01T00:00:00Z",
                    "updatedAt": "2024-01-02T00:00:00Z",
                    "additions": 10,
                    "deletions": 5,
                    "state": "OPEN",
                    "isDraft": false,
                    "reviewDecision": null,
                    "baseRefName": "main",
                    "headRefName": "fix-bug",
                    "headRefOid": "abc123",
                    "repository": {"nameWithOwner": "owner/repo"},
                    "author": {"login": "dev", "avatarUrl": null},
                    "commits": null,
                    "reviewThreads": {"totalCount": 0, "nodes": []},
                    "latestReviews": {"nodes": []},
                    "labels": {"nodes": []},
                    "timelineItems": null
                }
            ],
            "pageInfo": {"hasNextPage": false, "endCursor": null}
        }
        """
        let data = json.data(using: .utf8)!
        let result = try JSONDecoder().decode(SearchResult.self, from: data)
        #expect(result.nodes.count == 1)
        #expect(result.nodes[0].id == "PR_1")
        #expect(result.nodes[0].title == "Fix bug")
    }

    @Test("skips non-PullRequest nodes (Issues) gracefully")
    func skipsIssueNodes() throws {
        let json = """
        {
            "nodes": [
                {
                    "id": "ISSUE_1",
                    "title": "Bug report",
                    "url": "https://github.com/owner/repo/issues/1"
                },
                {
                    "id": "PR_2",
                    "number": 99,
                    "title": "Add feature",
                    "url": "https://github.com/owner/repo/pull/99",
                    "createdAt": "2024-02-01T00:00:00Z",
                    "updatedAt": "2024-02-02T00:00:00Z",
                    "additions": 50,
                    "deletions": 20,
                    "state": "OPEN",
                    "isDraft": true,
                    "reviewDecision": "REVIEW_REQUIRED",
                    "baseRefName": "main",
                    "headRefName": "add-feature",
                    "headRefOid": "def456",
                    "repository": {"nameWithOwner": "org/project"},
                    "author": {"login": "contributor", "avatarUrl": "https://example.com/avatar.png"},
                    "commits": null,
                    "reviewThreads": {"totalCount": 2, "nodes": [{"isResolved": true}, {"isResolved": false}]},
                    "latestReviews": {"nodes": []},
                    "labels": {"nodes": [{"name": "enhancement", "color": "a2eeef"}]},
                    "timelineItems": null
                }
            ],
            "pageInfo": {"hasNextPage": true, "endCursor": "cursor_abc"}
        }
        """
        let data = json.data(using: .utf8)!
        let result = try JSONDecoder().decode(SearchResult.self, from: data)
        // Should only contain the valid PR node, skipping the Issue
        #expect(result.nodes.count == 1)
        #expect(result.nodes[0].id == "PR_2")
        #expect(result.pageInfo.hasNextPage == true)
        #expect(result.pageInfo.endCursor == "cursor_abc")
    }

    @Test("handles empty nodes array")
    func emptyNodes() throws {
        let json = """
        {
            "nodes": [],
            "pageInfo": {"hasNextPage": false, "endCursor": null}
        }
        """
        let data = json.data(using: .utf8)!
        let result = try JSONDecoder().decode(SearchResult.self, from: data)
        #expect(result.nodes.isEmpty)
    }

    @Test("handles all-invalid nodes without crashing")
    func allInvalidNodes() throws {
        let json = """
        {
            "nodes": [
                {"id": "ISSUE_1", "title": "Bug 1"},
                {"id": "ISSUE_2", "title": "Bug 2"},
                {"garbage": true}
            ],
            "pageInfo": {"hasNextPage": false, "endCursor": null}
        }
        """
        let data = json.data(using: .utf8)!
        let result = try JSONDecoder().decode(SearchResult.self, from: data)
        #expect(result.nodes.isEmpty)
    }

    @Test("skips null nodes and keeps surrounding PRs", .timeLimit(.minutes(1)))
    func skipsNullNodes() throws {
        let json = """
        {
            "nodes": [
                \(makePRNodeJSON(id: "PR_1", number: 1)),
                null,
                {"id": "ISSUE_1", "title": "Bug report"},
                null,
                \(makePRNodeJSON(id: "PR_2", number: 2))
            ],
            "pageInfo": {"hasNextPage": false, "endCursor": null}
        }
        """
        let data = try #require(json.data(using: .utf8))
        let result = try JSONDecoder().decode(SearchResult.self, from: data)
        #expect(result.nodes.count == 2)
        #expect(result.nodes.map(\.id) == ["PR_1", "PR_2"])
        // Nulls are not "skipped nodes with an id" — only the Issue counts.
        #expect(result.skippedNodeCount == 1)
    }

    @Test("handles all-null nodes", .timeLimit(.minutes(1)))
    func allNullNodes() throws {
        let json = """
        {
            "nodes": [null, null],
            "pageInfo": {"hasNextPage": false, "endCursor": null}
        }
        """
        let data = try #require(json.data(using: .utf8))
        let result = try JSONDecoder().decode(SearchResult.self, from: data)
        #expect(result.nodes.isEmpty)
        #expect(result.skippedNodeCount == 0)
    }

    @Test("throws on a scalar node instead of looping", .timeLimit(.minutes(1)))
    func scalarNodeThrows() throws {
        let json = """
        {
            "nodes": [42],
            "pageInfo": {"hasNextPage": false, "endCursor": null}
        }
        """
        let data = try #require(json.data(using: .utf8))
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SearchResult.self, from: data)
        }
    }

    // MARK: - Helpers

    private func makePRNodeJSON(id: String, number: Int) -> String {
        """
        {
            "id": "\(id)",
            "number": \(number),
            "title": "PR \(number)",
            "url": "https://github.com/owner/repo/pull/\(number)",
            "createdAt": "2024-01-01T00:00:00Z",
            "updatedAt": "2024-01-02T00:00:00Z",
            "additions": 10,
            "deletions": 5,
            "state": "OPEN",
            "isDraft": false,
            "reviewDecision": null,
            "baseRefName": "main",
            "headRefName": "branch-\(number)",
            "headRefOid": "abc\(number)",
            "repository": {"nameWithOwner": "owner/repo"},
            "author": {"login": "dev", "avatarUrl": null},
            "commits": null,
            "reviewThreads": {"totalCount": 0, "nodes": []},
            "latestReviews": {"nodes": []},
            "labels": {"nodes": []},
            "timelineItems": null
        }
        """
    }
}
